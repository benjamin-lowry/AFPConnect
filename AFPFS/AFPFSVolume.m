//
//  AFPFSVolume.m
//  AFPFS
//
//  Created by Benjamin Lowry on 2026-11-06.
//

#import "AFPFSVolume.h"
#import "AFPFSAttributes.h"
#import "AFPFSItem.h"
#import "AFPFSMetadataStore.h"

#import "AFPCInternal.h"
#import "AFPCEncoding.h"
#import "AFPCKeychain.h"
#import "AFPCNames.h"
#import "AFPCSession.h"

#import <IOKit/IOMessage.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <os/log.h>
#import <sys/stat.h>

static os_log_t vol_log(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.benjaminlowry.AFPConnect.AFPFS", "volume");
    });
    return log;
}

static NSError *posix(int err)
{
    return fs_errorForPOSIXError(err);
}

/// maximum number of requests in progress at once
static const long kMaxRequests = 8;

/// filename prefix for a file waiting to be deleted by the server
static NSString *const kDeletedPrefix = @".afpfs-deleted-";

/// returns YES/NO whether the given file is hidden (AppleDouble or a file pending delete)
static BOOL isHiddenName(NSString *name)
{
    return [name hasPrefix:@"._"] || [name hasPrefix:kDeletedPrefix];
}

#pragma mark - mount target

@implementation AFPFSMountTarget

+ (instancetype)targetWithURL:(NSURL *)url error:(NSError **)error
{
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *volume = [c.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if (!c || [c.scheme caseInsensitiveCompare:@"afp"] != NSOrderedSame || !c.host.length) {
        if (error) {
            *error = posix(EINVAL);
        }
        return nil;
    }
    if (c.password.length) {
        os_log_error(vol_log(), "refusing a password in the url, use -o password= instead");
        if (error) {
            *error = posix(EINVAL);
        }
        return nil;
    }
    if (!volume.length || [volume containsString:@"/"]) {
        os_log_error(vol_log(), "the url needs exactly one volume name");
        if (error) {
            *error = posix(EINVAL);
        }
        return nil;
    }

    AFPFSMountTarget *t = [[AFPFSMountTarget alloc] init];
    t.host = c.host;
    t.port = c.port ? c.port.unsignedShortValue : 548;
    // afp urls put the uam after the user, as in user;AUTH=DHX2
    NSString *user = [c.user componentsSeparatedByString:@";"].firstObject;
    t.user = user.length ? user : nil;
    t.volumeName = volume;
    return t;
}

@end

#pragma mark - directory entries

@interface AFPFSEntry : NSObject
@property (copy) NSString *name;
@property struct afp_dirent dirent;
@property CFAbsoluteTime fetched;
@end

/// how long a cached dirent will be used for lookups/getattr calls made after it was cached
static const CFAbsoluteTime kDirentLifetime = 2;
static const NSUInteger kMaxDirents = 4096;

@implementation AFPFSEntry
@end

#pragma mark - volume

@implementation AFPFSVolume {
    AFPFSMountTarget *_target;
    AFPCSession *_session;
    struct afp_volume *_vol;
    AFPFSItem *_root;

    /// mapping of cnid to item
    NSMapTable<NSNumber *, AFPFSItem *> *_items;
    NSHashTable<AFPFSItem *> *_openItems;

    dispatch_queue_t _queue;
    dispatch_semaphore_t _slots;
    /// YES if closeSession has closed this session
    BOOL _closed;
    /// mapping of path to its cached dirent lookup (see kDirentLifetime)
    NSMutableDictionary<NSString *, AFPFSEntry *> *_dirents;
    uint64_t _direntGeneration;
    NSUInteger _direntSweepAt;
    /// stores items made by this session that cannot be read back (i.e. made in a Drop Box)
    NSMutableDictionary<NSString *, AFPFSItem *> *_blind;
    uint32_t _blindCount;
    /// set of items with a resource fork handle opened at item creation time
    NSMutableSet<AFPFSItem *> *_earlyForkItems;
    // sleep notices:
    io_connect_t _powerRoot;
    IONotificationPortRef _powerPort;
    io_object_t _powerNotifier;
    BOOL _suspended;
    uint64_t _wakes;

    FSStatFSResult *_stats;
    NSDate *_statsTime;

    /// list of paths for files pending deletion
    NSMutableSet<NSString *> *_pendingDeletes;

    dispatch_source_t _clockTimer;

    /// pointer to the metadata store generating AppleDouble files for this volume
    AFPFSMetadataStore *_meta;
}

- (instancetype)initWithVolumeID:(FSVolumeIdentifier *)volumeID target:(AFPFSMountTarget *)target
{
    /* fskit creates the /Volumes/[volume] mount point for us,
       failing with EINVAL if there are non-ASCII characters in the mount point.
       So we call AFPCMountPointName to create an ASCII-only mount point name
       based on the policy set in the app's defaults group; we can't look up
       the setting via a mount option because we don't get those until activation,
       which occurs after init (so after the mount point has been fixed) */
    self = [super initWithVolumeID:volumeID volumeName:[FSFileName nameWithString:AFPCMountPointName(target.volumeName, AFPCConvertNamesEnabled())]];
    if (self) {
        _target = target;
        _items = [NSMapTable strongToWeakObjectsMapTable];
        _openItems = [NSHashTable weakObjectsHashTable];
        _queue = dispatch_queue_create("com.benjaminlowry.AFPConnect.AFPFS.requests", DISPATCH_QUEUE_CONCURRENT);
        _slots = dispatch_semaphore_create(kMaxRequests);
        _pendingDeletes = [NSMutableSet set];
        _dirents = [NSMutableDictionary dictionary];
        _blind = [NSMutableDictionary dictionary];
        _earlyForkItems = [NSMutableSet set];
    }
    return self;
}

/// Used to run a blocking libafpclient call
- (void)run:(void (^)(void))block
{
    [self run:block afterClose:NO];
}

- (void)run:(void (^)(void))block afterClose:(BOOL)afterClose
{
    dispatch_async(_queue, ^{
        dispatch_semaphore_wait(self->_slots, DISPATCH_TIME_FOREVER);
        if (self->_closed && !afterClose) {
            os_log_error(vol_log(), "dropping a request made after unmount");
        } else {
            block();
        }
        dispatch_semaphore_signal(self->_slots);
    });
}

#pragma mark paths and lookups

// ml_* paths are precomposed utf-8
static const char *cpath(NSString *path)
{
    return path.precomposedStringWithCanonicalMapping.UTF8String;
}

static NSString *childPath(AFPFSItem *dir, NSString *name)
{
    NSString *base = dir.path;
    return [base isEqualToString:@"/"] ? [@"/" stringByAppendingString:name]
                                       : [NSString stringWithFormat:@"%@/%@", base, name];
}

/// Returns a dirent for the given path (from the cache if we already looked up the path within the last two seconds)
- (int)getDirent:(struct afp_dirent *)e forPath:(NSString *)path
{
    uint64_t generation;
    @synchronized (_dirents) {
        AFPFSEntry *cached = _dirents[path];
        if (cached && CFAbsoluteTimeGetCurrent() - cached.fetched < kDirentLifetime) {
            *e = cached.dirent;
            return 0;
        }
        generation = _direntGeneration;
    }
    int ret = [self fetchDirent:e forPath:path];
    if (ret == 0) {
        AFPFSEntry *entry = [[AFPFSEntry alloc] init];
        entry.dirent = *e;
        entry.fetched = CFAbsoluteTimeGetCurrent();
        @synchronized (_dirents) {
            if (generation == _direntGeneration) {
                _dirents[path] = entry;
            }
            if (_dirents.count > MAX(kMaxDirents, _direntSweepAt)) {
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                NSMutableArray *stale = [NSMutableArray array];
                [_dirents enumerateKeysAndObjectsUsingBlock:^(NSString *key, AFPFSEntry *e, BOOL *stop) {
                    if (now - e.fetched >= kDirentLifetime) {
                        [stale addObject:key];
                    }
                }];
                [_dirents removeObjectsForKeys:stale];
                _direntSweepAt = _dirents.count * 2;
            }
        }
    }
    return ret;
}

/// Drop all the dirents we've cached; do this before and after we make a change
- (void)forgetDirents
{
    @synchronized (_dirents) {
        _direntGeneration++;
        [_dirents removeAllObjects];
    }
}

- (int)fetchDirent:(struct afp_dirent *)e forPath:(NSString *)path
{
    struct afp_volume *vol = _vol;
    char basename[AFPC_MAX_NAME_BYTES];
    unsigned int dirid;
    int ret = AFPFSResolvePath(vol, path, &dirid, basename);
    if (ret < 0) {
        return ret;
    }

    BOOL afp3 = vol->server->using_version->av_number >= 30;
    unsigned int dirbitmap =   kFPAttributeBit | kFPCreateDateBit | kFPModDateBit | kFPNodeIDBit
                             | kFPParentDirIDBit | kFPOffspringCountBit | kFPFinderInfoBit;
    unsigned int filebitmap =   kFPAttributeBit | kFPCreateDateBit | kFPModDateBit | kFPNodeIDBit
                              | kFPParentDirIDBit | kFPFinderInfoBit
                              | (afp3 ? kFPExtDataForkLenBit | kFPExtRsrcForkLenBit
                                      : kFPDataForkLenBit | kFPRsrcForkLenBit);
    if (vol->extra_flags & VOLUME_EXTRA_FLAGS_VOL_SUPPORTS_UNIX) {
        dirbitmap  |= kFPUnixPrivsBit;
        filebitmap |= kFPUnixPrivsBit;
    } else {
        dirbitmap |= kFPOwnerIDBit | kFPGroupIDBit | kFPAccessRightsBit;
    }

    memset(e, 0, sizeof(*e));
    switch ((ret = afp_getfiledirparms(vol, dirid, filebitmap, dirbitmap, basename, e))) {
    case kFPNoErr:
        return 0;
    case kFPAccessDenied:
        return -EACCES;
    case kFPObjectNotFound:
        return -ENOENT;
    default:
        return ret == ETIMEDOUT ? -ETIMEDOUT : -EIO;
    }
}

- (AFPFSItem *)itemForCNID:(uint32_t)cnid name:(NSString *)name parent:(AFPFSItem *)parent
               isDirectory:(BOOL)isDirectory
{
    if (cnid == FSItemIDRootDirectory) {
        return _root;
    }
    @synchronized (_items) {
        AFPFSItem *item = [_items objectForKey:@(cnid)];
        if (item && item.isDirectory == isDirectory) {
            if (item.parent != parent || ![item.name isEqualToString:name]) {
                [item setParent:parent name:name];
            }
            return item;
        }
        item = [[AFPFSItem alloc] initWithCNID:cnid name:name parent:parent isDirectory:isDirectory];
        [_items setObject:item forKey:@(cnid)];
        return item;
    }
}

- (FSItemAttributes *)attributesOf:(AFPFSItem *)item error:(int *)err
{
    if (item.blind) {
        return [self blindAttributesOf:item];
    }
    struct afp_dirent e;
    int ret = [self getDirent:&e forPath:item.path];
    if (ret < 0) {
        *err = -ret;
        return nil;
    }
    return [self reportAttributesOf:item dirent:&e];
}

// attributes for the kernel
- (FSItemAttributes *)reportAttributesOf:(AFPFSItem *)item dirent:(const struct afp_dirent *)e
{
    @synchronized (item) {
        item.attrsReported = YES;
        item.reportedModTime = e->mod_ns;
        item.reportedSize = e->size;
    }
    return [self attributesFromDirent:e isRoot:item == _root parent:item.parent];
}

#pragma mark blind items

/// Attributes for a blind item; tell the kernel it's rw so its xattrs can be listed
- (FSItemAttributes *)blindAttributesOf:(AFPFSItem *)item
{
    FSItemAttributes *a = [[FSItemAttributes alloc] init];
    a.type = item.isDirectory ? FSItemTypeDirectory : FSItemTypeFile;
    a.mode = item.isDirectory ? (S_IFDIR | 0333) : (S_IFREG | 0600);
    a.uid = getuid();
    a.gid = getgid();
    a.flags = 0;
    a.linkCount = item.isDirectory ? 2 : 1;
    @synchronized (item) {
        a.size = item.isDirectory ? 24 : item.blindSize;
    }
    a.allocSize = (a.size + 4095) & ~(uint64_t)4095;
    a.fileID = item.itemID;
    a.parentID = item.parent ? item.parent.itemID : FSItemIDParentOfRoot;
    a.birthTime = a.modifyTime = a.changeTime = a.accessTime = a.addedTime = item.blindTime;
    a.backupTime = (struct timespec){ 0, 0 };
    a.supportsLimitedXAttrs = NO;
    a.inhibitKernelOffloadedIO = YES;
    return a;
}

- (AFPFSItem *)makeBlindNamed:(NSString *)name inDirectory:(AFPFSItem *)dir isDirectory:(BOOL)isDirectory
{
    @synchronized (_blind) {
        AFPFSItem *item = [[AFPFSItem alloc] initBlindNamed:name parent:dir itemID:AFPFSBlindID(++_blindCount)
            isDirectory:isDirectory];
        _blind[item.path] = item;
        return item;
    }
}

- (AFPFSItem *)blindItemAt:(NSString *)path
{
    @synchronized (_blind) {
        return _blind[path];
    }
}

- (void)forgetBlindItemAt:(NSString *)path
{
    @synchronized (_blind) {
        [_blind removeObjectForKey:path];
    }
}

- (void)moveBlindItem:(AFPFSItem *)item from:(NSString *)oldPath
{
    @synchronized (_blind) {
        [_blind removeObjectForKey:oldPath];
        _blind[item.path] = item;
    }
}

#pragma mark early resource forks

/// how long a file's early resource fork handle stays open after its last close
static const double kEarlyForkHold = 10;

- (BOOL)canSeeFilesIn:(AFPFSItem *)dir
{
    struct afp_dirent e;
    return [self getDirent:&e forPath:dir.path] < 0 || AFPFSCanSeeFiles(&e);
}

- (void)holdEarlyFork:(struct afp_file_info *)fork for:(AFPFSItem *)item
{
    [item holdEarlyFork:fork];
    @synchronized (_earlyForkItems) {
        [_earlyForkItems addObject:item];
    }
}

- (void)closeEarlyFork:(struct afp_file_info *)fork
{
    if (fork) {
        afp_closefork(_vol, fork->forkid);
        remove_opened_fork(_vol, fork);
        free(fork);
    }
}

- (void)releaseEarlyForkOf:(AFPFSItem *)item
{
    [self closeEarlyFork:[item takeEarlyFork]];
    @synchronized (_earlyForkItems) {
        [_earlyForkItems removeObject:item];
    }
}

/// release an early resource fork handle once AppleDouble is committed, so the server stops treating the file as busy
- (void)releaseEarlyForkSoon:(AFPFSItem *)item
{
    @synchronized (_earlyForkItems) {
        if (![_earlyForkItems containsObject:item]) {
            return;
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kEarlyForkHold * NSEC_PER_SEC)), _queue, ^{
        dispatch_semaphore_wait(self->_slots, DISPATCH_TIME_FOREVER);
        BOOL open;
        @synchronized (item) {
            open = item.openCount > 0;
        }
        if (self->_vol && !open) {
            [self releaseEarlyForkOf:item];
        }
        dispatch_semaphore_signal(self->_slots);
    });
}

/// Fetch an item's attributes from the dirent cache (e.g. for files getting ther permissions from their containing folders)
- (FSItemAttributes *)attributesFromDirent:(const struct afp_dirent *)e isRoot:(BOOL)isRoot
                                    parent:(AFPFSItem *)parent
{
    struct afp_dirent pe;
    BOOL haveParent = !isRoot && parent && AFPFSNeedsParentRights(e) && [self getDirent:&pe forPath:parent.path] == 0;
    return AFPFSAttributesFromDirent(_vol, e, isRoot, _session, haveParent ? &pe : NULL);
}

- (void)invalidateListingOf:(AFPFSItem *)dir
{
    @synchronized (dir) {
        dir.listing = nil;
    }
}

#pragma mark capabilities and statistics

- (BOOL)afp3
{
    return _vol && _vol->server->using_version->av_number >= 30;
}

- (FSVolumeSupportedCapabilities *)supportedVolumeCapabilities
{
    FSVolumeSupportedCapabilities *c = [[FSVolumeSupportedCapabilities alloc] init];
    BOOL afp3 = self.afp3;
    BOOL unixPrivs = _vol && (_vol->extra_flags & VOLUME_EXTRA_FLAGS_VOL_SUPPORTS_UNIX);
    c.supportsPersistentObjectIDs = afp3;
    c.supports64BitObjectIDs = YES;
    // lock symlinks behind AFP 3.1 or later;
    // AFP 3.0 (Mac OS X 10.1) implements unix perms but doesn't properly handle symlinks
    c.supportsSymbolicLinks = unixPrivs && _vol->server->using_version->av_number >= 31;
    c.supportsHardLinks = NO;
    c.supportsHiddenFiles = YES;
    c.supports2TBFiles = afp3;
    c.doesNotSupportSettingFilePermissions = !unixPrivs;
    c.caseFormat = (_vol && (_vol->attributes & kCaseSensitive)) ? FSVolumeCaseFormatSensitive
                                                                 : FSVolumeCaseFormatInsensitiveCasePreserving;
    return c;
}

- (FSStatFSResult *)volumeStatistics
{
    @synchronized (self) {
        if (_stats && -_statsTime.timeIntervalSinceNow < 5) {
            return _stats;
        }
        FSStatFSResult *s = [[FSStatFSResult alloc] initWithFileSystemTypeName:@"afp"];
        struct statvfs st;
        memset(&st, 0, sizeof(st));
        if (_vol && ml_statfs(_vol, "/", &st) == 0) {
            uint64_t bsize = st.f_frsize ?: st.f_bsize ?: 4096;
            s.blockSize = (NSInteger)bsize;
            s.ioSize = 128 * 1024;
            s.totalBlocks = st.f_blocks;
            s.freeBlocks = st.f_bfree;
            s.availableBlocks = st.f_bavail;
            s.usedBlocks = st.f_blocks - st.f_bfree;
            s.totalBytes = st.f_blocks * bsize;
            s.freeBytes = st.f_bfree * bsize;
            s.availableBytes = st.f_bavail * bsize;
            s.usedBytes = s.usedBlocks * bsize;
            // Finder refuses to copy to a volume with no free files
            s.totalFiles = st.f_files ?: st.f_blocks;
            s.freeFiles = st.f_ffree ?: st.f_bavail;
        }
        _stats = s;
        _statsTime = [NSDate date];
        return s;
    }
}

- (NSInteger)maximumLinkCount { return 1; }
- (NSInteger)maximumNameLength { return self.afp3 ? 255 : 31; }
- (BOOL)restrictsOwnershipChanges { return YES; }
- (BOOL)truncatesLongNames { return NO; }
/// Returns the maximum file size allowed by ``ll_write`` and ``ll_setfork_size`` (``INT64_MAX`` on AFP 3 and ``AFP_MAX_AFP2_FILESIZE`` on AFP 2)
- (uint64_t)maximumFileSize { return self.afp3 ? INT64_MAX : AFP_MAX_AFP2_FILESIZE; }

// AFP doesn't allow unix-style deletion of open files,
// this tells FSKit to emulate deletion of open files by hiding them and deferring the delete.
- (BOOL)enableOpenUnlinkEmulation { return YES; }

#pragma mark mount and activate

/// Converts -o key=value options to a dictionary, split on commas
static NSDictionary<NSString *, NSString *> *mountOptions(FSTaskOptions *options)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *opt in options.taskOptions) {
        for (NSString *part in [opt componentsSeparatedByString:@","]) {
            NSRange eq = [part rangeOfString:@"="];
            if (eq.location != NSNotFound) {
                result[[part substringToIndex:eq.location]] = [part substringFromIndex:NSMaxRange(eq)];
            } else if (part.length && ![part isEqualToString:@"-o"]) {
                result[part] = @"";
            }
        }
    }
    return result;
}

- (nullable NSString *)passwordFromOptions:(NSDictionary<NSString *, NSString *> *)opts
{
    if (opts[@"password"]) {
        return opts[@"password"];
    }
    if (opts[@"token"]) {
        return [AFPCKeychain getAndDeleteOneShotPasswordForToken:opts[@"token"]];
    }
    if (_target.user) {
        return [AFPCKeychain passwordForHost:_target.host user:_target.user];
    }
    return nil;
}

static NSString *volumePasswordFromOptions(NSDictionary<NSString *, NSString *> *opts)
{
    if (opts[@"volpassword"]) {
        return opts[@"volpassword"];
    }
    if (opts[@"voltoken"]) {
        return [AFPCKeychain getAndDeleteOneShotPasswordForToken:opts[@"voltoken"]];
    }
    return nil;
}

/// Returns the AFPCClockPolicy currently enabled based on the timefix parameter in the given options dictionary.
static AFPCClockPolicy clockPolicyFromOptions(NSDictionary<NSString *, NSString *> *opts)
{
    NSString *value = opts[@"timefix"];
    if ([value isEqualToString:@"zone"]) {
        return AFPCClockPolicyZone;
    }
    if ([value isEqualToString:@"local"]) {
        return AFPCClockPolicyLocal;
    }
    if (value && ![value isEqualToString:@"all"]) {
        os_log_error(vol_log(), "unknown timefix=%{public}@, using timefix=all", value);
    }
    return AFPCClockPolicyAll;
}

- (void)activateVolumeWithOptions:(FSTaskOptions *)options
                     replyHandler:(void (^)(FSActivateResult *, NSError *))reply
{
    // This function has to succeed! fskit_agent will hang if it doesn't!
    // (at least it will on 27.2.1)
    // Therefore, retry and error handling have to happen here
    
    NSDictionary *opts = mountOptions(options);
    // The real name now that the mount point exists (see initWithVolumeID)
    self.name = [FSFileName nameWithString:self->_target.volumeName];
    NSString *password = [self passwordFromOptions:opts];
    NSString *volumePassword = volumePasswordFromOptions(opts);
    AFPCClockPolicy policy = clockPolicyFromOptions(opts);
    // check the encoding parameter for the encoding of filenames on an AFP 2 server
    // fall back to macroman if the encoding is unknown
    NSString *encoding = opts[@"encoding"] ?: @"macroman";
    if (![AFPCEncoding useEncodingNamed:encoding]) {
        os_log_error(vol_log(), "unknown encoding=%{public}@, using macroman", encoding);
        [AFPCEncoding useEncodingNamed:@"macroman"];
    }
    [self run:^{
        if (self->_target.user && !password) {
            os_log_error(vol_log(), "no password for %{private}@", self->_target.user);
            reply(nil, posix(EAUTH));
            return;
        }
        NSError *error = nil;
        AFPCSession *session = nil;
        // Attempt the connection a couple times (with a short wait between them),
        // since the App Sandbox will sometimes deny the first attempt due to an outdated
        // local network access permission.
        for (int attempt = 0; attempt < 4; attempt++) {
            session = [AFPCSession connectToHost:self->_target.host port:self->_target.port
                                            user:self->_target.user password:password
                                    keepPassword:YES error:&error];
            if (session || (error.code != EHOSTUNREACH && error.code != ENETUNREACH)) {
                break;
            }
            sleep(1);
        }
        if (!session && (error.code == EHOSTUNREACH || error.code == ENETUNREACH)) {
            os_log_error(vol_log(), "%{public}@ is unreachable. if it's on the local network, make sure AFPConnect is enabled in System Settings > Privacy & Security > Local Network",
                         self->_target.host);
        }
        if (!session) {
            os_log_error(vol_log(), "connect failed: %{public}@", error);
            reply(nil, error.code == EACCES ? posix(EAUTH) : posix((int)error.code));
            return;
        }
        struct afp_volume *vol = [session openVolumeNamed:self->_target.volumeName password:volumePassword error:&error];
        if (!vol) {
            os_log_error(vol_log(), "open failed: %{public}@", error);
            [session close];
            reply(nil, posix((int)error.code));
            return;
        }
        session.clockPolicy = policy;
        self->_session = session;
        self->_vol = vol;
        self->_root = [[AFPFSItem alloc] initWithCNID:FSItemIDRootDirectory name:@"" parent:nil isDirectory:YES];
        __weak AFPFSVolume *weakSelf = self;
        self->_meta = [[AFPFSMetadataStore alloc] initWithVolume:vol scheduler:^(double delay, dispatch_block_t block) {
            AFPFSVolume *volume = weakSelf;
            if (!volume) {
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), volume->_queue, ^{
                dispatch_semaphore_wait(volume->_slots, DISPATCH_TIME_FOREVER);
                if (volume->_vol) {
                    block();
                }
                dispatch_semaphore_signal(volume->_slots);
            });
        }];
        self->_meta.serverChanged = ^{
            [weakSelf forgetDirents];
        };
        [self startClockChecks];
        [self startPowerNotices];
#if DEBUG
        // debugsleep: force sleep/wake handling regardless of whether the AFP host actually slept
        double debugSleep = [opts[@"debugsleep"] doubleValue];
        if (debugSleep > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(debugSleep * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [weakSelf suspendForSleep:^{
                    os_log(vol_log(), "debugsleep: slept");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        [weakSelf resumeAfterWake];
                    });
                }];
            });
        }
#endif
        os_log(vol_log(), "activated %{public}@ (afp %d, clock offset %ld s, %{public}@)", self->_target.volumeName,
               vol->server->using_version->av_number, (long)session.clockSkew, AFPCEncoding.currentName);
        reply([[FSActivateResult alloc] initWithRootItem:self->_root], nil);
    }];
}

#pragma mark sleep and wake

static void powerMessage(void *refcon, io_service_t service, natural_t type, void *argument)
{
    AFPFSVolume *volume = (__bridge AFPFSVolume *)refcon;
    io_connect_t root = volume->_powerRoot;
    switch (type) {
    case kIOMessageCanSystemSleep:
        IOAllowPowerChange(root, (long)argument);
        break;
    case kIOMessageSystemWillSleep:
        [volume suspendForSleep:^{
            IOAllowPowerChange(root, (long)argument);
        }];
        break;
    case kIOMessageSystemWillPowerOn:
    case kIOMessageSystemHasPoweredOn:
        [volume resumeAfterWake];
        break;
    default:
        break;
    }
}

// AFP 3 servers that can resume sessions will accept a reconnect with the session token.

- (void)startPowerNotices
{
    if (!self.afp3 || !(_vol->server->flags & kSupportsReconnect)) {
        return;
    }
    _powerRoot = IORegisterForSystemPower((__bridge void *)self, &_powerPort, powerMessage, &_powerNotifier);
    if (!_powerRoot) {
        os_log_error(vol_log(), "no sleep notices, the server will drop the session when the mac sleeps");
        return;
    }
    IONotificationPortSetDispatchQueue(_powerPort, dispatch_queue_create("com.benjaminlowry.AFPConnect.power", DISPATCH_QUEUE_SERIAL));
}

- (void)stopPowerNotices
{
    if (_powerRoot) {
        IODeregisterForSystemPower(&_powerNotifier);
        IOServiceClose(_powerRoot);
        IONotificationPortDestroy(_powerPort);
        _powerRoot = 0;
        _powerPort = NULL;
    }
}

- (void)suspendForSleep:(dispatch_block_t)done
{
    __block BOOL finished = NO;
    NSObject *lock = [[NSObject alloc] init];
    void (^finish)(void) = ^{
        @synchronized (lock) {
            if (finished) {
                return;
            }
            finished = YES;
        }
        done();
    };
    uint64_t wakes;
    @synchronized (self) {
        wakes = _wakes;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), finish);
    [self run:^{
        BOOL late;
        @synchronized (lock) {
            late = finished;
        }
        @synchronized (self) {
            late = late || self->_wakes != wakes;
        }
        if (late) {
            os_log(vol_log(), "too late to tell the server about the sleep");
            finish();
            return;
        }
        struct afp_server *server = self->_vol->server;
        int ret = afp_zzzzz(server);
        if (ret == 0) {
            // wake can also come while the server was being told
            @synchronized (self) {
                if (self->_wakes == wakes) {
                    afp_server_set_suspended(server, 1);
                    loop_disconnect(server);
                    self->_suspended = YES;
                }
            }
            os_log(vol_log(), "told the server about the sleep");
        } else {
            os_log(vol_log(), "server refused the sleep notice (%d) and may drop the session", ret);
        }
        finish();
    }];
}

- (void)resumeAfterWake
{
    @synchronized (self) {
        _wakes++;
    }
    [self run:^{
        @synchronized (self) {
            if (self->_suspended) {
                self->_suspended = NO;
                afp_server_set_suspended(self->_vol->server, 0);
                os_log(vol_log(), "woke back up, will reconnect on next request");
            }
        }
    }];
}

/// Begin polling the server clock to detect a time zone change while the share is mounted.
- (void)startClockChecks
{
    _clockTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_clockTimer, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC),
                              300 * NSEC_PER_SEC, 10 * NSEC_PER_SEC);
    __weak AFPFSVolume *weakSelf = self;
    dispatch_source_set_event_handler(_clockTimer, ^{
        AFPFSVolume *volume = weakSelf;
        if (!volume) {
            return;
        }
        dispatch_semaphore_wait(volume->_slots, DISPATCH_TIME_FOREVER);
        if ([volume->_session refreshClockSkew]) {
            os_log(vol_log(), "server clock offset is now %ld s", (long)volume->_session.clockSkew);
        }
        dispatch_semaphore_signal(volume->_slots);
    });
    dispatch_resume(_clockTimer);
}

/// Commit any pending writes before unmount.
- (void)finishWrites
{
    [_meta commitAll];
    NSArray<AFPFSItem *> *early;
    @synchronized (_earlyForkItems) {
        early = _earlyForkItems.allObjects;
    }
    for (AFPFSItem *item in early) {
        [self releaseEarlyForkOf:item];
    }
    NSArray *pending;
    @synchronized (_pendingDeletes) {
        pending = _pendingDeletes.allObjects;
    }
    for (NSString *path in pending) {
        if (![self tryPendingDelete:path]) {
            os_log_error(vol_log(), "leaving pending-delete file %{private}@ behind (server still won't delete it)", path);
        }
    }
    // copy the list of open items since closeForkOf acquires the item's lock
    NSArray<AFPFSItem *> *open;
    @synchronized (_openItems) {
        open = _openItems.allObjects;
    }
    for (AFPFSItem *item in open) {
        [self closeForkOf:item];
    }
}

/// This is the last call FSKit makes on the volume, it logs out and frees the session.
- (void)closeSession
{
    if (_closed) {
        return;
    }
    for (long i = 1; i < kMaxRequests; i++) {
        dispatch_semaphore_wait(_slots, DISPATCH_TIME_FOREVER);
    }
    if (_clockTimer) {
        dispatch_source_cancel(_clockTimer);
        _clockTimer = nil;
    }
    [self stopPowerNotices];
    // if our session is suspended, reconnect so we can inform the server we're logging out
    if (_suspended && _vol) {
        _suspended = NO;
        afp_server_set_suspended(_vol->server, 0);
    }
    if (_vol) {
        [self finishWrites];
    }
    _meta = nil;
    @synchronized (self) {
        [_session close];
        _session = nil;
        _vol = NULL;
    }
    _closed = YES;
    for (long i = 1; i < kMaxRequests; i++) {
        dispatch_semaphore_signal(_slots);
    }
}

- (void)deactivateVolumeWithOptions:(FSDeactivateOptions)options replyHandler:(void (^)(NSError *))reply
{
    [self run:^{
        [self closeSession];
        reply(nil);
    } afterClose:YES];
}

- (void)mountWithOptions:(FSTaskOptions *)options replyHandler:(void (^)(NSError *))reply
{
    reply(nil);
}

- (void)unmountWithReplyHandler:(void (^)(void))reply
{
    [self run:^{
        if (self->_vol) {
            [self finishWrites];
        }
        reply();
    } afterClose:YES];
}

- (void)synchronizeWithFlags:(FSSyncFlags)flags replyHandler:(void (^)(NSError *))reply
{
    [self run:^{
        [self->_meta commitAll];
        NSArray<AFPFSItem *> *open;
        @synchronized (self->_openItems) {
            open = self->_openItems.allObjects;
        }
        for (AFPFSItem *item in open) {
            @synchronized (item) {
                if (item.fork && item.forkWritable) {
                    ml_fsync(self->_vol, item.fork);
                }
            }
        }
        reply(nil);
    }];
}

- (void)reclaimItem:(FSItem *)fsItem replyHandler:(void (^)(NSError *))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    [self run:^{
        if (item.kind == AFPFSItemKindDouble) {
            [self->_meta reclaim:item];
            reply(nil);
            return;
        }
        [self closeForkOf:item];
        [self releaseEarlyForkOf:item];
        @synchronized (self->_items) {
            if ([self->_items objectForKey:@(item.cnid)] == item) {
                [self->_items removeObjectForKey:@(item.cnid)];
            }
        }
        reply(nil);
    }];
}

#pragma mark doubles

/// Returns the AppleDouble item corresponding to name (which starts with .\_) in dir, or nil (and an errno)
- (AFPFSItem *)doubleNamed:(NSString *)name inDirectory:(AFPFSItem *)dir create:(BOOL)create
                attributes:(FSItemAttributes **)attrs error:(int *)err
{
    NSString *baseName = [name substringFromIndex:2];
    if (!baseName.length || isHiddenName(baseName)) {
        *err = ENOENT;
        return nil;
    }
    struct afp_dirent e;
    int ret = [self getDirent:&e forPath:childPath(dir, baseName)];
    AFPFSItem *blind = ret == -EACCES ? [self blindItemAt:childPath(dir, baseName)] : nil;
    if (blind) {
        // blind file (made in a Drop Box), so it can only have the metadata we gave it
        memset(&e, 0, sizeof(e));
        e.isdir = blind.isDirectory ? 0x80 : 0;
        AFPFSItem *dbl = [_meta doubleFor:blind dirent:&e create:create error:err];
        if (dbl) {
            *attrs = [_meta attributesOfDouble:dbl baseAttributes:[self blindAttributesOf:blind]];
        }
        return dbl;
    }
    if (ret < 0) {
        *err = ret == -EACCES ? ENOENT : -ret;
        return nil;
    }
    AFPFSItem *base = [self itemForCNID:e.cnid name:baseName parent:dir isDirectory:e.isdir != 0];
    AFPFSItem *dbl = [_meta doubleFor:base dirent:&e create:create error:err];
    if (dbl) {
        *attrs = [_meta attributesOfDouble:dbl baseAttributes:[self attributesFromDirent:&e isRoot:NO parent:dir]];
    }
    return dbl;
}

- (FSItemAttributes *)attributesOfDouble:(AFPFSItem *)dbl error:(int *)err
{
    FSItemAttributes *base = [self attributesOf:dbl.base error:err];
    return base ? [_meta attributesOfDouble:dbl baseAttributes:base] : nil;
}

#pragma mark namespace

- (void)lookupItemNamed:(FSFileName *)name inDirectory:(FSItem *)directory context:(FSContext *)context
           replyHandler:(void (^)(FSLookupItemResult *, NSError *))reply
{
    AFPFSItem *dir = (AFPFSItem *)directory;
    NSString *n = name.string.precomposedStringWithCanonicalMapping;
    [self run:^{
        // AppleDouble files are synthesized metadata and not real files on the server
        if ([n hasPrefix:@"._"]) {
            int err = 0;
            FSItemAttributes *attrs = nil;
            AFPFSItem *dbl = [self doubleNamed:n inDirectory:dir create:NO attributes:&attrs error:&err];
            reply(dbl ? [[FSLookupItemResult alloc] initWithFoundItem:dbl
                                                             itemName:[FSFileName nameWithString:n]
                                                       itemAttributes:attrs] : nil,
                  dbl ? nil : posix(err));
            return;
        }
        if (!n.length || isHiddenName(n)) {
            reply(nil, posix(ENOENT));
            return;
        }
        struct afp_dirent e;
        int ret = [self getDirent:&e forPath:childPath(dir, n)];
        if (ret < 0) {
            // Pre-OS X servers give us EACCES for a name in a folder we don't have read access on (i.e. Drop Box), and file is only created after ENOENT; if a file actually exists at that path we get EEXIST
            AFPFSItem *blind = ret == -EACCES ? [self blindItemAt:childPath(dir, n)] : nil;
            if (blind) {
                reply([[FSLookupItemResult alloc] initWithFoundItem:blind
                                                           itemName:[FSFileName nameWithString:n]
                                                     itemAttributes:[self blindAttributesOf:blind]], nil);
                return;
            }
            if (ret == -ENOENT || ret == -EACCES) {
                [dir noteMissedName:n];
            }
            reply(nil, posix(ret == -EACCES ? ENOENT : -ret));
            return;
        }
        AFPFSItem *item = [self itemForCNID:e.cnid name:n parent:dir isDirectory:e.isdir != 0];
        reply([[FSLookupItemResult alloc] initWithFoundItem:item
                                                   itemName:[FSFileName nameWithString:n]
                                             itemAttributes:[self reportAttributesOf:item dirent:&e]], nil);
    }];
}

- (void)createItemNamed:(FSFileName *)name type:(FSItemType)type inDirectory:(FSItem *)directory
             attributes:(FSItemSetAttributesRequest *)newAttributes context:(FSContext *)context
           replyHandler:(void (^)(FSCreateItemResult *, NSError *))reply
{
    AFPFSItem *dir = (AFPFSItem *)directory;
    NSString *n = name.string.precomposedStringWithCanonicalMapping;
    mode_t mode = [newAttributes isValid:FSItemAttributeMode] ? (newAttributes.mode & 07777)
                                                               : (type == FSItemTypeDirectory ? 0755 : 0644);
    [self run:^{
        [self forgetDirents];
        if ([n hasPrefix:@"._"] && type == FSItemTypeFile) {
            // This is xnu making an AppleDouble for a file's first xattr
            int err = 0;
            FSItemAttributes *attrs = nil;
            AFPFSItem *dbl = [self doubleNamed:n inDirectory:dir create:YES attributes:&attrs error:&err];
            FSItemAttributes *dirAttrs = dbl ? [self attributesOf:dir error:&err] : nil;
            newAttributes.consumedAttributes |= FSItemAttributeMode;
            [self forgetDirents];
            reply(dbl ? [[FSCreateItemResult alloc] initWithNewItem:dbl
                                                        newItemName:[FSFileName nameWithString:n]
                                                  newItemAttributes:attrs
                                                directoryAttributes:dirAttrs ?: [[FSItemAttributes alloc] init]
                                                          freeSpace:nil] : nil,
                  dbl ? nil : posix(err == ENOENT ? ENOENT : err));
            return;
        }
        if (!n.length || isHiddenName(n)) {
            [self forgetDirents];
            reply(nil, posix(EACCES));
            return;
        }
        NSString *path = childPath(dir, n);
        int ret;
        if (type == FSItemTypeDirectory) {
            ret = ml_mkdir(self->_vol, cpath(path), mode);
        } else if (type == FSItemTypeFile) {
            unsigned char created = 0;
            // Creator must be able to write a read-only file it just made,
            // so mode does not apply until last close
            ret = ml_creat(self->_vol, cpath(path), mode | S_IWUSR, &created);
        } else {
            ret = -ENOTSUP;
        }
        if (ret < 0) {
            [self forgetDirents];
            reply(nil, posix(-ret));
            return;
        }
        struct afp_file_info *early = NULL;
        if (type == FSItemTypeFile && ![self canSeeFilesIn:dir]
                && AFPFSOpenForkWriteOnly(self->_vol, path, YES, 0, &early) < 0) {
            early = NULL;
        }

        struct afp_dirent e;
        if ((ret = [self getDirent:&e forPath:path]) == -EACCES) {
            // File made in a Drop Box
            AFPFSItem *item = [self makeBlindNamed:n inDirectory:dir isDirectory:type == FSItemTypeDirectory];
            if (early) {
                [self holdEarlyFork:early for:item];
            }
            newAttributes.consumedAttributes |= FSItemAttributeMode;
            int err = 0;
            [self forgetDirents];
            FSItemAttributes *dirAttrs = [self attributesOf:dir error:&err];
            [self forgetDirents];
            reply([[FSCreateItemResult alloc] initWithNewItem:item
                                                  newItemName:[FSFileName nameWithString:n]
                                            newItemAttributes:[self blindAttributesOf:item]
                                          directoryAttributes:dirAttrs ?: [[FSItemAttributes alloc] init]
                                                    freeSpace:nil], nil);
            return;
        }
        if (ret < 0) {
            [self closeEarlyFork:early];
            [self forgetDirents];
            reply(nil, posix(-ret));
            return;
        }
        AFPFSItem *item = [self itemForCNID:e.cnid name:n parent:dir isDirectory:type == FSItemTypeDirectory];
        if (early) {
            [self holdEarlyFork:early for:item];
        }
        if (type == FSItemTypeFile && !(mode & S_IWUSR)) {
            @synchronized (item) {
                item.hasPendingMode = YES;
                item.pendingMode = mode;
            }
        }
        newAttributes.consumedAttributes |= FSItemAttributeMode;
        [self invalidateListingOf:dir];

        int err = 0;
        [self forgetDirents];
        FSItemAttributes *dirAttrs = [self attributesOf:dir error:&err];
        [self forgetDirents];
        reply([[FSCreateItemResult alloc] initWithNewItem:item
                                              newItemName:[FSFileName nameWithString:n]
                                        newItemAttributes:[self attributesFromDirent:&e isRoot:NO parent:dir]
                                      directoryAttributes:dirAttrs ?: [[FSItemAttributes alloc] init]
                                                freeSpace:nil], nil);
    }];
}

- (void)createSymbolicLinkNamed:(FSFileName *)name inDirectory:(FSItem *)directory
                     attributes:(FSItemSetAttributesRequest *)newAttributes
                   linkContents:(FSFileName *)contents context:(FSContext *)context
                   replyHandler:(void (^)(FSCreateSymlinkResult *, NSError *))reply
{
    AFPFSItem *dir = (AFPFSItem *)directory;
    NSString *n = name.string.precomposedStringWithCanonicalMapping;
    NSString *target = contents.string;
    [self run:^{
        [self forgetDirents];
        if (!self.supportedVolumeCapabilities.supportsSymbolicLinks || !target || isHiddenName(n)) {
            [self forgetDirents];
            reply(nil, posix(ENOTSUP));
            return;
        }
        NSString *path = childPath(dir, n);
        int ret = ml_symlink(self->_vol, target.UTF8String, cpath(path));
        struct afp_dirent e;
        if (ret < 0 || (ret = [self getDirent:&e forPath:path]) < 0) {
            [self forgetDirents];
            reply(nil, posix(-ret));
            return;
        }
        AFPFSItem *item = [self itemForCNID:e.cnid name:n parent:dir isDirectory:NO];
        [self invalidateListingOf:dir];
        int err = 0;
        [self forgetDirents];
        FSItemAttributes *dirAttrs = [self attributesOf:dir error:&err];
        [self forgetDirents];
        reply([[FSCreateSymlinkResult alloc] initWithNewItem:item
                                                 newItemName:[FSFileName nameWithString:n]
                                           newItemAttributes:[self attributesFromDirent:&e isRoot:NO parent:dir]
                                         directoryAttributes:dirAttrs ?: [[FSItemAttributes alloc] init]
                                                   freeSpace:nil], nil);
    }];
}

- (void)createLinkToItem:(FSItem *)item named:(FSFileName *)name inDirectory:(FSItem *)directory
                 context:(FSContext *)context
            replyHandler:(void (^)(FSCreateLinkResult *, NSError *))reply
{
    reply(nil, posix(ENOTSUP));
}

- (void)readSymbolicLink:(FSItem *)fsItem context:(FSContext *)context
            replyHandler:(void (^)(FSReadSymlinkResult *, NSError *))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    [self run:^{
        char buf[PATH_MAX + 1] = { 0 };
        int ret = ml_readlink(self->_vol, cpath(item.path), buf, sizeof(buf) - 1);
        int err = 0;
        FSItemAttributes *attrs = ret < 0 ? nil : [self attributesOf:item error:&err];
        if (ret < 0 || !attrs) {
            reply(nil, posix(ret < 0 ? -ret : err));
            return;
        }
        reply([[FSReadSymlinkResult alloc] initWithContents:[FSFileName nameWithCString:buf]
                                          symlinkAttributes:attrs], nil);
    }];
}

- (void)removeItem:(FSItem *)fsItem named:(FSFileName *)name fromDirectory:(FSItem *)directory
           context:(FSContext *)context
      replyHandler:(void (^)(FSRemoveItemResult *, NSError *))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    AFPFSItem *dir = (AFPFSItem *)directory;
    [self run:^{
        [self forgetDirents];
        int err = 0;
        if (item.kind == AFPFSItemKindDouble) {
            // last xattr was deleted, or the AppleDouble itself was
            [self forgetDirents];
            FSItemAttributes *attrs = [self attributesOfDouble:item error:&err];
            int ret = [self->_meta removeMetadataOf:item];
            [self forgetDirents];
            FSItemAttributes *dirAttrs = [self attributesOf:dir error:&err];
            [self forgetDirents];
            reply(ret < 0 ? nil : [[FSRemoveItemResult alloc] initWithItemAttributes:attrs ?: [[FSItemAttributes alloc] init]
                                                                  directoryAttributes:dirAttrs ?: [[FSItemAttributes alloc] init]
                                                                            freeSpace:nil],
                  ret < 0 ? posix(-ret) : nil);
            return;
        }
        [self forgetDirents];
        FSItemAttributes *attrs = [self attributesOf:item error:&err];
        if (!attrs && err == ENOENT && !item.blind) {
            // Another client deleted it already, which is what was asked for
            os_log(vol_log(), "remove %{private}@: already gone from the server", item.path);
            [self closeForkOf:item];
            [self releaseEarlyForkOf:item];
            [self->_meta forgetLocalAttributesOf:item];
            FSItemAttributes *dirAttrs = [self attributesOf:dir error:&err];
            [self forgetDirents];
            reply([[FSRemoveItemResult alloc] initWithItemAttributes:[[FSItemAttributes alloc] init]
                                                 directoryAttributes:dirAttrs ?: [[FSItemAttributes alloc] init]
                                                           freeSpace:nil], nil);
            return;
        }
        if (!attrs) {
            [self forgetDirents];
            reply(nil, posix(err));
            return;
        }
        [self closeForkOf:item];
        [self releaseEarlyForkOf:item];
        [self->_meta releaseForksOf:item];

        int ret;
        if (item.isDirectory) {
            ret = ml_rmdir(self->_vol, cpath(item.path));
        } else {
            ret = ml_unlink(self->_vol, cpath(item.path));
            // If server won't let us delete this file yet (another client has it open),
            // defer its deletion (i.e. unix behavior for deleting an empty file)
            if ((ret == -ENOTEMPTY || ret == -EBUSY) && [self deferDeleteOf:item]) {
                ret = 0;
            } else if (ret == -ENOTEMPTY) {
                ret = -EBUSY;
            }
        }
        // Another client deleted it already, which is what was asked for
        if (ret == -ENOENT && !item.blind) {
            os_log(vol_log(), "remove %{private}@: already gone from the server", item.path);
            ret = 0;
        }
        if (ret < 0) {
            os_log_error(vol_log(), "remove %{public}@ (dir %d): %d", item.path, item.isDirectory, ret);
            [self forgetDirents];
            reply(nil, posix(-ret));
            return;
        }
        if (item.blind) {
            [self forgetBlindItemAt:item.path];
        }
        [self->_meta forgetLocalAttributesOf:item];
        [self invalidateListingOf:dir];
        [self forgetDirents];
        FSItemAttributes *dirAttrs = [self attributesOf:dir error:&err];
        [self forgetDirents];
        reply([[FSRemoveItemResult alloc] initWithItemAttributes:attrs
                                             directoryAttributes:dirAttrs ?: [[FSItemAttributes alloc] init]
                                                       freeSpace:nil], nil);
    }];
}

- (void)renameItem:(FSItem *)fsItem inDirectory:(FSItem *)sourceDirectory named:(FSFileName *)sourceName
         toNewName:(FSFileName *)destinationName inDirectory:(FSItem *)destinationDirectory
          overItem:(FSItem *)overItem context:(FSContext *)context
      replyHandler:(void (^)(FSRenameItemResult *, NSError *))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    AFPFSItem *src = (AFPFSItem *)sourceDirectory;
    AFPFSItem *dst = (AFPFSItem *)destinationDirectory;
    AFPFSItem *over = (AFPFSItem *)overItem;
    NSString *newName = destinationName.string.precomposedStringWithCanonicalMapping;
    [self run:^{
        [self forgetDirents];
        int err = 0;
        if (item.kind == AFPFSItemKindDouble) {
            // xnu rename of an AppleDouble file
            if (![newName hasPrefix:@"._"]) {
                [self forgetDirents];
                reply(nil, posix(EACCES));
                return;
            }
            [self forgetDirents];
            FSItemAttributes *attrs = [self attributesOfDouble:item error:&err];
            [self forgetDirents];
            FSItemAttributes *srcAttrs = [self attributesOf:src error:&err];
            FSItemAttributes *dstAttrs = src == dst ? srcAttrs : [self attributesOf:dst error:&err];
            FSItemAttributes *none = [[FSItemAttributes alloc] init];
            [self forgetDirents];
            reply([[FSRenameItemResult alloc] initWithNewName:[FSFileName nameWithString:newName]
                                        renamedItemAttributes:attrs ?: none
                                    sourceDirectoryAttributes:srcAttrs ?: none
                               destinationDirectoryAttributes:dstAttrs ?: none
                                           overItemAttributes:nil
                                                    freeSpace:nil], nil);
            return;
        }
        if (!newName.length || isHiddenName(newName)) {
            [self forgetDirents];
            reply(nil, posix(EACCES));
            return;
        }
        FSItemAttributes *overAttrs = over ? [self attributesOf:over error:&err] : nil;
        if (over) {
            [self closeForkOf:over];
            [self releaseEarlyForkOf:over];
            [self->_meta releaseForksOf:over];
        }
        // pre-OS X AFP servers deny renames of files with any handle on a fork open
        [self releaseEarlyForkOf:item];
        [self->_meta releaseForksOf:item];
        NSString *oldPath = item.path;
        // ml_rename deletes an existing destination itself
        int ret = ml_rename(self->_vol, cpath(item.path), cpath(childPath(dst, newName)));
        os_log_debug(vol_log(), "rename %{public}@ -> %{public}@ over %{public}@: %d", item.path,
                     childPath(dst, newName), over.path, ret);
        if (ret < 0) {
            [self forgetDirents];
            reply(nil, posix(-ret));
            return;
        }
        [item setParent:dst name:newName];
        if (item.blind) {
            [self moveBlindItem:item from:oldPath];
        }
        [self invalidateListingOf:src];
        [self invalidateListingOf:dst];

        [self forgetDirents];
        FSItemAttributes *attrs = [self attributesOf:item error:&err];
        [self forgetDirents];
        FSItemAttributes *srcAttrs = [self attributesOf:src error:&err];
        FSItemAttributes *dstAttrs = src == dst ? srcAttrs : [self attributesOf:dst error:&err];
        FSItemAttributes *empty = [[FSItemAttributes alloc] init];
        [self forgetDirents];
        reply([[FSRenameItemResult alloc] initWithNewName:[FSFileName nameWithString:newName]
                                    renamedItemAttributes:attrs ?: empty
                                sourceDirectoryAttributes:srcAttrs ?: empty
                           destinationDirectoryAttributes:dstAttrs ?: empty
                                       overItemAttributes:overAttrs
                                                freeSpace:nil], nil);
    }];
}

- (void)getAttributes:(FSItemGetAttributesRequest *)desiredAttributes ofItem:(FSItem *)fsItem
              context:(FSContext *)context
         replyHandler:(void (^)(FSGetAttributesResult *, NSError *))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    [self run:^{
        int err = 0;
        FSItemAttributes *attrs = item.kind == AFPFSItemKindDouble ? [self attributesOfDouble:item error:&err]
                                                                   : [self attributesOf:item error:&err];
        reply(attrs ? [[FSGetAttributesResult alloc] initWithAttributes:attrs] : nil,
              attrs ? nil : posix(err));
        if (err == ENOENT && item.kind == AFPFSItemKindNode && item != self->_root) {
            [self revokeItems:@[ item ]];
        }
    }];
}

- (void)setAttributes:(FSItemSetAttributesRequest *)req onItem:(FSItem *)fsItem
              context:(FSContext *)context
         replyHandler:(void (^)(FSSetAttributesResult *, NSError *))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    [self run:^{
        [self forgetDirents];
        int ret = 0;
        if (item.kind == AFPFSItemKindDouble) {
            // Only the size means anything for an AppleDouble file
            if ([req isValid:FSItemAttributeSize] && (ret = [self->_meta truncate:item size:req.size]) < 0) {
                [self forgetDirents];
                reply(nil, posix(-ret));
                return;
            }
            req.consumedAttributes = FSItemAttributeSize | FSItemAttributeMode | FSItemAttributeUID
                                     | FSItemAttributeGID | FSItemAttributeFlags | FSItemAttributeAccessTime
                                     | FSItemAttributeModifyTime | FSItemAttributeChangeTime
                                     | FSItemAttributeBirthTime | FSItemAttributeBackupTime
                                     | FSItemAttributeAddedTime;
            int err = 0;
            [self forgetDirents];
            FSItemAttributes *attrs = [self attributesOfDouble:item error:&err];
            [self forgetDirents];
            reply(attrs ? [[FSSetAttributesResult alloc] initWithAttributes:attrs freeSpace:nil] : nil,
                  attrs ? nil : posix(err));
            return;
        }
        const char *path = cpath(item.path);

        if ([req isValid:FSItemAttributeSize]) {
            @synchronized (item) {
                ret = (item.fork && item.forkWritable) ? ml_ftruncate(self->_vol, item.fork, (off_t)req.size)
                                                       : ml_truncate(self->_vol, path, (off_t)req.size);
            }
            if (ret < 0) {
                [self forgetDirents];
                reply(nil, posix(-ret));
                return;
            }
            if (item.blind) {
                @synchronized (item) {
                    item.blindSize = req.size;
                }
            }
            req.consumedAttributes |= FSItemAttributeSize;
        }

        unsigned int which = 0;
        mode_t mode = 0;
        time_t mtime = 0;
        if ([req isValid:FSItemAttributeMode]) {
            which |= ML_SET_MODE;
            mode = req.mode & 07777;
        }
        if ([req isValid:FSItemAttributeModifyTime]) {
            which |= ML_SET_MTIME;
            mtime = [self->_session serverTimeFromLocal:req.modifyTime.tv_sec];
        }
        // Don't allow creation date to be later than mtime
        if ((which & ML_SET_MTIME) && ![req isValid:FSItemAttributeBirthTime]) {
            struct afp_dirent cur;
            if ([self getDirent:&cur forPath:item.path] == 0 && (cur.valid & kFPCreateDateBit)) {
                struct timespec created = [self->_session localTimeFromServer:afp_dirent_time(self->_vol, &cur, kFPCreateDateBit, cur.create_ns)];
                if (req.modifyTime.tv_sec < created.tv_sec) {
                    AFPFSSetCreationDate(self->_vol, item.path, mtime);
                }
            }
        }

        int err = 0;
        ret = AFPFSApplyMetadata(self->_vol, item.path, req, self->_session);
        // Drop Boxes may not let us read back an item in order to change it
        if (ret < 0 && !(item.blind && ret == -EACCES)) {
            [self forgetDirents];
            reply(nil, posix(-ret));
            return;
        }

        if (which) {
            ret = ml_setattr(self->_vol, path, which, mode, 0, 0, mtime);
            // mirroring fuse_fs.c
            if (ret < 0 && ret != -EPERM && ret != -ENOSYS && ret != -EACCES) {
                [self forgetDirents];
                reply(nil, posix(-ret));
                return;
            }
            req.consumedAttributes |= FSItemAttributeMode | FSItemAttributeModifyTime;
        }
        if (which & ML_SET_MTIME) {
            @synchronized (item) {
                // AFP 2 servers set a file's mtime when its fork is closed
                if (item.fork && item.forkWritable) {
                    item.hasPendingModTime = YES;
                    item.pendingModTime = mtime;
                }
            }
        }

        // Accept and drop ownership and timestamps that AFP doesn't save
        req.consumedAttributes |= FSItemAttributeUID | FSItemAttributeGID | FSItemAttributeAccessTime
                                  | FSItemAttributeChangeTime | FSItemAttributeBackupTime
                                  | FSItemAttributeAddedTime;

        [self forgetDirents];
        FSItemAttributes *attrs = [self attributesOf:item error:&err];
        [self forgetDirents];
        reply(attrs ? [[FSSetAttributesResult alloc] initWithAttributes:attrs freeSpace:nil] : nil,
              attrs ? nil : posix(err));
    }];
}

- (void)enumerateDirectory:(FSItem *)directory startingAtCookie:(FSDirectoryCookie)cookie
                  verifier:(FSDirectoryVerifier)verifier
       providingAttributes:(FSItemGetAttributesRequest *)attributes
               usingPacker:(FSDirectoryEntryPacker *)packer context:(FSContext *)context
              replyHandler:(void (^)(FSEnumerateDirectoryResult *, NSError *))reply
{
    AFPFSItem *dir = (AFPFSItem *)directory;
    [self run:^{
        os_log_debug(vol_log(), "enumerate %{public}@ cookie %llu attrs %d", dir.path, cookie, attributes != nil);
        NSArray<AFPFSEntry *> *entries;
        uint64_t current;
        @synchronized (dir) {
            if (cookie != FSDirectoryCookieInitial && dir.listing && verifier != dir.listingVerifier) {
                reply(nil, [NSError errorWithDomain:FSKitErrorDomain code:FSErrorInvalidDirectoryCookie userInfo:nil]);
                return;
            }
            entries = dir.listing;
            current = dir.listingVerifier;
        }

        NSArray<AFPFSItem *> *stale = nil;
        BOOL missed = NO;
        if (cookie == FSDirectoryCookieInitial || !entries) {
            struct afp_listing l;
            memset(&l, 0, sizeof(l));
            CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
            int ret = ml_readdir(self->_vol, cpath(dir.path), &l);
            os_log_debug(vol_log(), "listing %{public}@: %d, %u entries", dir.path, ret, l.count);
            if (ret < 0) {
                afp_listing_free(&l);
                reply(nil, posix(-ret));
                return;
            }
            NSMutableArray *fresh = [NSMutableArray arrayWithCapacity:l.count];
            for (uint32_t i = 0; i < l.count; i++) {
                NSString *n = [NSString stringWithUTF8String:l.pool + l.entries[i].name_off];
                // Don't let real AppleDouble files on the server collide with our synthesized metadata
                if (!n.length || isHiddenName(n)) {
                    continue;
                }
                AFPFSEntry *entry = [[AFPFSEntry alloc] init];
                entry.name = n;
                entry.dirent = l.entries[i];
                [fresh addObject:entry];
            }
            afp_listing_free(&l);
            stale = [self staleItemsIn:dir listing:fresh since:started];
            missed = [dir takeMissedNamesIn:[fresh valueForKey:@"name"]];
            @synchronized (dir) {
                dir.listing = fresh;
                dir.listingVerifier = (dir.listingVerifier + 1) ?: 1;
                entries = fresh;
                current = dir.listingVerifier;
            }
        }

        // Invalidate a file that the listing shows another client changed
        NSMutableArray<AFPFSItem *> *changed = [NSMutableArray array];
        if (cookie == FSDirectoryCookieInitial) {
            for (AFPFSEntry *entry in entries) {
                struct afp_dirent e = entry.dirent;
                AFPFSItem *known;
                @synchronized (self->_items) {
                    known = [self->_items objectForKey:@(e.cnid)];
                }
                if (!known || known.isDirectory) {
                    continue;
                }
                @synchronized (known) {
                    if (known.attrsReported && (known.reportedModTime != e.mod_ns || known.reportedSize != e.size)) {
                        known.reportedModTime = e.mod_ns;
                        known.reportedSize = e.size;
                        [changed addObject:known];
                    }
                }
            }
        }

        // Dot entries only without attributes
        NSUInteger dots = attributes ? 0 : 2;
        for (NSUInteger idx = (NSUInteger)cookie; idx < entries.count + dots; idx++) {
            BOOL ok;
            if (idx < dots) {
                AFPFSItem *target = idx == 0 ? dir : (dir.parent ?: dir);
                ok = [packer packEntryWithName:[FSFileName nameWithString:idx == 0 ? @"." : @".."]
                                      itemType:FSItemTypeDirectory
                                        itemID:target.itemID
                                    nextCookie:idx + 1
                                    attributes:nil];
            } else {
                AFPFSEntry *entry = entries[idx - dots];
                struct afp_dirent e = entry.dirent;
                FSItemAttributes *a = attributes ? [self attributesFromDirent:&e isRoot:NO parent:dir] : nil;
                ok = [packer packEntryWithName:[FSFileName nameWithString:entry.name]
                                      itemType:AFPFSItemTypeOfDirent(&e)
                                        itemID:e.cnid
                                    nextCookie:idx + 1
                                    attributes:a];
            }
            if (!ok) {
                break;
            }
        }
        reply([[FSEnumerateDirectoryResult alloc] initWithVerifier:current], nil);
        [self revokeItems:stale];
        if (missed) {
            [self purgeNamesIn:dir];
        }
        if (changed.count) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                for (AFPFSItem *item in changed) {
                    NSError *error = [self setCacheStateForItem:item cacheMode:FSDataCacheModeNone
                                                  coherencyType:FSKernelCacheCoherencyTypeNoCache
                                                coherencyAction:FSKernelCacheCoherencyActionInvalidate];
                    if (error) {
                        os_log_debug(vol_log(), "couldn't invalidate %{private}@: %{public}@", item.path, error);
                    }
                }
            });
        }
    }];
}

#pragma mark items deleted elsewhere

/// Tells the kernel to drop items another client deleted/renamed from its cache; if we don't, it will retain the now-stale name forever, blocking future writes to that filename and potentially displaying the outdated name in the Finder.
- (void)revokeItems:(NSArray<AFPFSItem *> *)items
{
    if (!items.count) {
        return;
    }
    // Clear the dirent cache so the kernel doesn't get the stale item back
    [self forgetDirents];
    // each item with its appledouble first
    NSMutableArray<AFPFSItem *> *all = [NSMutableArray arrayWithCapacity:items.count];
    for (AFPFSItem *item in items) {
        AFPFSItem *dbl = [_meta existingDoubleOf:item];
        if (dbl) {
            [all addObject:dbl];
        }
        [all addObject:item];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (AFPFSItem *item in all) {
            os_log(vol_log(), "revoking %{private}@, gone or renamed on the server", item.path);
            NSError *error = [self setCacheStateForItem:item cacheMode:FSDataCacheModeNone
                                          coherencyType:FSKernelCacheCoherencyTypeNoCache
                                        coherencyAction:FSKernelCacheCoherencyActionRevoke];
            if (error) {
                os_log_error(vol_log(), "couldn't revoke %{private}@: %{public}@", item.path, error);
            }
        }
        // Revoking a folder leaves its name in its parent's name cache, so we need to invalidate the parent too
        NSMutableSet<AFPFSItem *> *parents = [NSMutableSet set];
        for (AFPFSItem *item in items) {
            if (item.isDirectory && item.parent) {
                [parents addObject:item.parent];
            }
        }
        for (AFPFSItem *parent in parents) {
            NSError *error = [self setCacheStateForItem:parent cacheMode:FSDataCacheModeNone
                                          coherencyType:FSKernelCacheCoherencyTypeNoCache
                                        coherencyAction:FSKernelCacheCoherencyActionInvalidate];
            if (error) {
                os_log_debug(vol_log(), "couldn't invalidate %{private}@: %{public}@", parent.path, error);
            }
        }
    });
}

/// Purges kernel's cache of dir; can only use this on folders, attempting to do this on the root gives BadArgument
- (void)purgeNamesIn:(AFPFSItem *)dir
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = [self setCacheStateForItem:dir cacheMode:FSDataCacheModeNone
                                      coherencyType:FSKernelCacheCoherencyTypeNoCache
                                    coherencyAction:FSKernelCacheCoherencyActionInvalidate];
        if (error) {
            os_log_debug(vol_log(), "couldn't invalidate %{private}@: %{public}@", dir.path, error);
        }
    });
}

/// Returns the list of AFPFSItems in dir that no longer exist that the kernel might still have in its cache.
- (NSArray<AFPFSItem *> *)staleItemsIn:(AFPFSItem *)dir listing:(NSArray<AFPFSEntry *> *)entries
                                 since:(CFAbsoluteTime)started
{
    NSMutableDictionary<NSNumber *, NSString *> *present = [NSMutableDictionary dictionaryWithCapacity:entries.count];
    for (AFPFSEntry *entry in entries) {
        present[@(entry.dirent.cnid)] = entry.name;
    }
    NSArray<AFPFSItem *> *known;
    @synchronized (_items) {
        known = _items.objectEnumerator.allObjects;
    }
    NSMutableArray<AFPFSItem *> *gone = [NSMutableArray array];
    for (AFPFSItem *item in known) {
        if (item == _root || item.blind || item.placedAt >= started) {
            continue;
        }
        NSString *name = present[@(item.cnid)];
        if (name) {
            if (item.parent != dir || ![item.name isEqualToString:name]) {
                [item setParent:dir name:name];
                [gone addObject:item];
            }
        } else if (item.parent == dir && !isHiddenName(item.name)) {
            [gone addObject:item];
        }
    }
    // Need to revoke a folder's contents before the folder itself, so we revoke deepest items first
    NSMutableArray<AFPFSItem *> *under = [NSMutableArray array];
    for (AFPFSItem *dirGone in gone) {
        if (!dirGone.isDirectory) {
            continue;
        }
        for (AFPFSItem *item in known) {
            for (AFPFSItem *up = item.parent; up; up = up.parent) {
                if (up == dirGone) {
                    [under addObject:item];
                    break;
                }
            }
        }
    }
    [under sortUsingComparator:^NSComparisonResult(AFPFSItem *a, AFPFSItem *b) {
        NSUInteger da = [a.path componentsSeparatedByString:@"/"].count, db = [b.path componentsSeparatedByString:@"/"].count;
        return da > db ? NSOrderedAscending : da < db ? NSOrderedDescending : NSOrderedSame;
    }];
    [under addObjectsFromArray:gone];
    return under;
}

#pragma mark deferred deletes

/// Renames item to a hidden name, and move it to the root directory if the root is writable (so the deferred file's containing directory can still be removed). Attempts to delete the file in the future will be scheduled.
- (BOOL)deferDeleteOf:(AFPFSItem *)item
{
    NSString *name = [kDeletedPrefix stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *hidden = [@"/" stringByAppendingString:name];
    if (ml_rename(_vol, cpath(item.path), cpath(hidden)) < 0) {
        hidden = childPath(item.parent ?: _root, name);
        if (ml_rename(_vol, cpath(item.path), cpath(hidden)) < 0) {
            return NO;
        }
    }
    os_log(vol_log(), "deferring delete of %{private}@", item.path);
    @synchronized (_pendingDeletes) {
        [_pendingDeletes addObject:hidden];
    }
    [self retryDeleteOf:hidden delay:2 waited:0];
    return YES;
}

- (void)retryDeleteOf:(NSString *)path delay:(double)delay waited:(double)waited
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        dispatch_semaphore_wait(self->_slots, DISPATCH_TIME_FOREVER);
        BOOL done = !self->_vol || [self tryPendingDelete:path];
        dispatch_semaphore_signal(self->_slots);
        // progressively double the delay, giving up after about ten minutes, allowing the unmount to make one more attempt
        if (!done && waited + delay < 600) {
            [self retryDeleteOf:path delay:MIN(delay * 2, 60) waited:waited + delay];
        }
    });
}

/// Attempt to delete the file at path that is pending a deferred deletion. Returns YES if the file was successfully deleted, the file is not pending a delete, or the file does not exist (i.e. already deleted); returns NO if the file is still pending delete and could not be deleted.
- (BOOL)tryPendingDelete:(NSString *)path
{
    @synchronized (_pendingDeletes) {
        if (![_pendingDeletes containsObject:path]) {
            return YES;
        }
    }
    int ret = ml_unlink(_vol, cpath(path));
    if (ret == 0 || ret == -ENOENT) {
        @synchronized (_pendingDeletes) {
            [_pendingDeletes removeObject:path];
        }
        return YES;
    }
    return NO;
}

#pragma mark forks

/// Opens the data fork of item if needed. Call inside @synchronized(item)
- (int)ensureForkOf:(AFPFSItem *)item writable:(BOOL)writable
{
    if (item.fork && (!writable || item.forkWritable)) {
        return 0;
    }
    struct afp_file_info *fp = NULL;
    uint64_t size;
    @synchronized (item) {
        size = item.blindSize;
    }
    // Cannot read or lookup a blind file (in a Drop Box)
    if (item.blind && !writable) {
        return -EACCES;
    }
    int ret = item.blind ? AFPFSOpenForkWriteOnly(_vol, item.path, NO, size, &fp)
                         : ml_open(_vol, cpath(item.path), writable ? O_RDWR : O_RDONLY, &fp);
    if (ret == -EACCES && writable && !item.blind) {
        // For a drop box file we haven't marked as blind, we should still be able to open the fork write-only, but we can't use ml_open since it always asks to read. This codepath sometimes triggers at least on 10.2 Jaguar
        struct afp_dirent e;
        uint64_t known = [self getDirent:&e forPath:item.path] == 0 ? e.size : 0;
        ret = AFPFSOpenForkWriteOnly(_vol, item.path, NO, known, &fp);
    }
    if (ret < 0) {
        return ret;
    }
    if (item.fork) {
        ml_close(_vol, item.fork);
        free(item.fork);
    }
    item.fork = fp;
    item.forkWritable = writable;
    @synchronized (_openItems) {
        [_openItems addObject:item];
    }
    return 0;
}

- (void)closeForkOf:(AFPFSItem *)item
{
    BOOL changed;
    @synchronized (item) {
        changed = (item.fork && item.forkWritable) || item.hasPendingMode || item.hasPendingModTime;
        if (item.fork) {
            // ml_close flushes the fork and closes it on the server, we now have to free the handle ourselves (see fuse_fs.c)
            ml_close(_vol, item.fork);
            free(item.fork);
            item.fork = NULL;
            item.forkWritable = NO;
        }
        item.openCount = 0;
        if (item.hasPendingMode) {
            item.hasPendingMode = NO;
            ml_set_created_mode(_vol, cpath(item.path), item.pendingMode);
        }
        // set the mtime after setting the mode since netatalk overwrites the mtime when changing privileges
        if (item.hasPendingModTime) {
            item.hasPendingModTime = NO;
            ml_setattr(_vol, cpath(item.path), ML_SET_MTIME, 0, 0, 0, item.pendingModTime);
        }
    }
    @synchronized (_openItems) {
        [_openItems removeObject:item];
    }
    if (changed) {
        [self forgetDirents];
    }
}

- (void)openItem:(FSItem *)fsItem withModes:(FSVolumeOpenModes)modes context:(FSContext *)context
    replyHandler:(void (^)(NSError *))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    [self run:^{
        if (item.kind == AFPFSItemKindDouble) {
            [self->_meta opened:item];
            reply(nil);
            return;
        }
        if (item.isDirectory) {
            reply(nil);
            return;
        }
        int ret;
        os_log_debug(vol_log(), "open %{public}@ modes=%lu", item.path, (unsigned long)modes);
        @synchronized (item) {
            ret = [self ensureForkOf:item writable:(modes & FSVolumeOpenModesWrite) != 0];
            if (ret == 0) {
                item.openCount++;
            }
        }
        reply(ret < 0 ? posix(-ret) : nil);
    }];
}

- (void)closeItem:(FSItem *)fsItem keepingModes:(FSVolumeOpenModes)modes context:(FSContext *)context
     replyHandler:(void (^)(NSError *))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    [self run:^{
        os_log_debug(vol_log(), "close %{public}@ keeping=%lu", item.path, (unsigned long)modes);
        if (item.kind == AFPFSItemKindDouble) {
            if (modes == 0) {
                [self->_meta closed:item];
            }
        } else if (!item.isDirectory && modes == 0) {
            [self closeForkOf:item];
            [self releaseEarlyForkSoon:item];
        }
        reply(nil);
    }];
}

- (void)readFromFile:(FSItem *)fsItem offset:(off_t)offset length:(size_t)length
          intoBuffer:(FSMutableFileDataBuffer *)buffer
        replyHandler:(void (^)(FSReadFileResult *, NSError *))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    [self run:^{
        os_log_debug(vol_log(), "read %{public}@ off=%lld len=%zu open=%lu", item.path, offset, length, (unsigned long)item.openCount);
        if (item.kind == AFPFSItemKindDouble) {
            size_t n = 0;
            int ret = [self->_meta read:item into:buffer.mutableBytes offset:offset length:MIN(length, buffer.length) bytesRead:&n];
            int err = 0;
            FSItemAttributes *attrs = ret < 0 ? nil : [self attributesOfDouble:item error:&err];
            reply(ret < 0 ? nil : [[FSReadFileResult alloc] initWithBytesRead:n
                                                            itemAttributes:attrs ?: [[FSItemAttributes alloc] init]],
                  ret < 0 ? posix(-ret) : nil);
            return;
        }
        size_t want = MIN(length, buffer.length);
        size_t total = 0;
        int ret = 0;
        BOOL transient = NO;
        @synchronized (item) {
            transient = item.openCount == 0;
            ret = [self ensureForkOf:item writable:NO];
            while (ret == 0 && total < want) {
                int eof = 0;
                int n = ml_read(self->_vol, (char *)buffer.mutableBytes + total, want - total,
                                offset + (off_t)total, item.fork, &eof);
                if (n < 0) {
                    ret = n;
                    break;
                }
                total += (size_t)n;
                if (eof || n == 0) {
                    break;
                }
            }
            if (transient && item.openCount == 0) {
                [self closeForkOf:item];
            }
        }
        if (ret < 0) {
            reply(nil, posix(-ret));
            return;
        }
        int err = 0;
        FSItemAttributes *attrs = [self attributesOf:item error:&err];
        reply([[FSReadFileResult alloc] initWithBytesRead:total itemAttributes:attrs ?: [[FSItemAttributes alloc] init]], nil);
    }];
}

- (void)writeContents:(NSData *)contents toFile:(FSItem *)fsItem atOffset:(off_t)offset
         replyHandler:(void (^)(FSWriteFileResult *, NSError *))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    [self run:^{
        [self forgetDirents];
        os_log_debug(vol_log(), "write %{public}@ off=%lld len=%lu open=%lu", item.path, offset, (unsigned long)contents.length, (unsigned long)item.openCount);
        if (item.kind == AFPFSItemKindDouble) {
            int ret = [self->_meta write:item data:contents offset:offset];
            int err = 0;
            FSItemAttributes *attrs = ret < 0 ? nil : [self attributesOfDouble:item error:&err];
            [self forgetDirents];
            reply(ret < 0 ? nil : [[FSWriteFileResult alloc] initWithBytesWritten:contents.length
                                                                  itemAttributes:attrs ?: [[FSItemAttributes alloc] init]
                                                                       freeSpace:nil],
                  ret < 0 ? posix(-ret) : nil);
            return;
        }
        size_t total = 0;
        int ret = 0;
        BOOL transient = NO;
        @synchronized (item) {
            transient = item.openCount == 0;
            ret = [self ensureForkOf:item writable:YES];
            while (ret == 0 && total < contents.length) {
                int n = ml_write(self->_vol, (const char *)contents.bytes + total, contents.length - total,
                                 offset + (off_t)total, item.fork);
                if (n <= 0) {
                    ret = n < 0 ? n : -EIO;
                    break;
                }
                total += (size_t)n;
            }
            if (transient && item.openCount == 0) {
                [self closeForkOf:item];
            }
        }
        if (ret < 0 && total == 0) {
            [self forgetDirents];
            reply(nil, posix(-ret));
            return;
        }
        @synchronized (self) {
            self->_stats = nil;
        }
        if (item.blind) {
            @synchronized (item) {
                item.blindSize = MAX(item.blindSize, (uint64_t)offset + total);
            }
        }
        int err = 0;
        [self forgetDirents];
        FSItemAttributes *attrs = [self attributesOf:item error:&err];
        [self forgetDirents];
        reply([[FSWriteFileResult alloc] initWithBytesWritten:total
                                               itemAttributes:attrs ?: [[FSItemAttributes alloc] init]
                                                    freeSpace:nil], nil);
    }];
}

#pragma mark kernel data cache

/// The type of caching to allow for an open in this mode. (Writers get write-through so their writes can reach the server before close returns)
static FSKernelCacheCoherencyType coherencyFor(FSDataCacheMode mode, BOOL writable)
{
    switch (mode) {
    case FSDataCacheModeReadWithCache:
        return FSKernelCacheCoherencyTypeReadCache;
    case FSDataCacheModeReadWriteWithCache:
        return writable ? FSKernelCacheCoherencyTypeWriteThrough : FSKernelCacheCoherencyTypeReadCache;
    default:
        return FSKernelCacheCoherencyTypeNoCache;
    }
}

- (void)openItem:(FSItem *)fsItem modes:(FSVolumeOpenModes)modes cacheMode:(FSDataCacheMode)cacheMode
         context:(FSContext *)context replyHandler:(void (^)(FSOpenItemResult *, NSError *))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    BOOL writable = (modes & FSVolumeOpenModesWrite) != 0;
    [self run:^{
        if (item.kind == AFPFSItemKindDouble) {
            [self->_meta opened:item];
            reply([[FSOpenItemResult alloc] initWithGrantedCoherency:FSKernelCacheCoherencyTypeNoCache], nil);
            return;
        }
        if (item.isDirectory) {
            reply([[FSOpenItemResult alloc] initWithGrantedCoherency:FSKernelCacheCoherencyTypeNoCache], nil);
            return;
        }
        int ret;
        BOOL stale = NO;
        struct afp_dirent e;
        [self forgetDirents];
        int got = [self getDirent:&e forPath:item.path];
        @synchronized (item) {
            ret = [self ensureForkOf:item writable:writable];
            if (ret == 0) {
                item.openCount++;
            }
            if (got == 0) {
                stale = item.cacheGranted && (e.mod_ns != item.seenModTime || e.size != item.seenSize);
                item.seenModTime = e.mod_ns;
                item.seenSize = e.size;
            }
        }
        if (ret < 0) {
            reply(nil, posix(-ret));
            if (ret == -ENOENT) {
                [self revokeItems:@[ item ]];
            }
            return;
        }
        FSKernelCacheCoherencyType granted = stale ? FSKernelCacheCoherencyTypeNoCache : coherencyFor(cacheMode, writable);
        @synchronized (item) {
            item.cacheGranted = granted != FSKernelCacheCoherencyTypeNoCache;
        }
        reply([[FSOpenItemResult alloc] initWithGrantedCoherency:granted], nil);
        if (stale) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSError *error = [self setCacheStateForItem:item cacheMode:FSDataCacheModeNone
                                              coherencyType:FSKernelCacheCoherencyTypeNoCache
                                            coherencyAction:FSKernelCacheCoherencyActionInvalidate];
                if (error) {
                    os_log_error(vol_log(), "couldn't drop cached data of %{private}@: %{public}@", item.path, error);
                }
            });
        }
    }];
}

- (void)closeItem:(FSItem *)fsItem context:(FSContext *)context replyHandler:(void (^)(void))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    [self run:^{
        if (item.kind == AFPFSItemKindDouble) {
            [self->_meta closed:item];
        } else if (!item.isDirectory) {
            [self closeForkOf:item];
            [self releaseEarlyForkSoon:item];
        }
        reply();
    }];
}

- (void)upgradeItem:(FSItem *)fsItem cacheMode:(FSDataCacheMode)cacheMode context:(FSContext *)context
       replyHandler:(void (^)(FSUpgradeItemResult *, NSError *))reply
{
    AFPFSItem *item = (AFPFSItem *)fsItem;
    FSKernelCacheCoherencyType granted = FSKernelCacheCoherencyTypeNoCache;
    if (item.kind == AFPFSItemKindNode && !item.isDirectory) {
        @synchronized (item) {
            granted = coherencyFor(cacheMode, item.forkWritable);
            item.cacheGranted = granted != FSKernelCacheCoherencyTypeNoCache;
        }
    }
    reply([[FSUpgradeItemResult alloc] initWithGrantedCoherency:granted], nil);
}

#pragma mark xattrs (inhibited)

/// Tells FSKit (right after loadResource called) that this volume does not support xattr operations. We need to do this in order for XNU to enable its AppleDouble fallback (allowing AFPFSMetadataStore to intercept operations on xattrs). Undocumented size limit on FSKit xattrs means we can't use the xattr handlers.
- (BOOL)xattrOperationsInhibited
{
    return YES;
}

- (void)getXattrNamed:(FSFileName *)name ofItem:(FSItem *)item context:(FSContext *)context
         replyHandler:(void (^)(FSGetXattrResult *, NSError *))reply
{
    reply(nil, posix(ENOTSUP));
}

- (void)setXattrNamed:(FSFileName *)name toData:(NSData *)value onItem:(FSItem *)item
               policy:(FSSetXattrPolicy)policy context:(FSContext *)context
         replyHandler:(void (^)(FSSetXattrResult *, NSError *))reply
{
    reply(nil, posix(ENOTSUP));
}

- (void)listXattrsOfItem:(FSItem *)item context:(FSContext *)context
            replyHandler:(void (^)(FSListXattrsResult *, NSError *))reply
{
    reply(nil, posix(ENOTSUP));
}

@end
