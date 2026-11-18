//
//  AFPFSMetadataStore.m
//  AFPFS
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import "AFPFSMetadataStore.h"
#import "AFPCEncoding.h"
#import "AFPFSAppleDouble.h"
#import "AFPFSAttributes.h"

#import <libkern/OSByteOrder.h>
#import <os/log.h>
#import <sys/stat.h>

static os_log_t md_log(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.benjaminlowry.AFPConnect.AFPFS", "metadata");
    });
    return log;
}

/// FPSetExtAttr limit from libafpclient
static const size_t kMaxServerXattr = 4096;
/// How long after a file close or write to wait before committing its AppleDouble
static const double kCommitDelay = 1.5;
static const size_t kCopyChunk = 128 * 1024;

/// Xattr name for the Finder comment for a file
static NSString *const kCommentName = @"com.apple.metadata:kMDItemFinderComment";
/// AFP limit on Finder comment length
static const size_t kMaxComment = 199;

/// Returns true if the given xattr name is reserved for server use
static BOOL isReservedXattrName(NSString *name)
{
    if ([name hasPrefix:@"user."]) {
        name = [name substringFromIndex:5];
    }
    return [name isEqualToString:@"com.apple.FinderInfo"] || [name isEqualToString:@"com.apple.ResourceFork"]
           || [name hasPrefix:@"org.netatalk.Metadata"];
}

@interface AFPFSDoubleState : NSObject
@property (nonatomic, strong) NSMutableData *header;
@property (nonatomic, readonly) uint64_t headerLength;
/// Clears header to save memory (~5kb header per file + a bunch of files accessed in a long session = wasted memory)
- (void)dropHeader;
@property (nonatomic) BOOL headerDirty;
/// Server fork length for unstaged file
@property (nonatomic) uint64_t forkLength;
/// Last fork offset xnu used for this file
@property (nonatomic) uint64_t forkOffsetHint;
/// Staged fd (-1 when not staged)
@property (nonatomic) int fd;
@property (nonatomic) BOOL staged;
@property (nonatomic) BOOL dirty;
/// Where the staged header says it ends (fork offset + length)
@property (nonatomic) uint64_t declaredEnd;
/// Open handle on the resource fork, for reads and commits
@property (nonatomic) struct afp_file_info *fork;
@property (nonatomic) BOOL forkWritable;
/// The server's FinderInfo (to diff against when committing)
@property (nonatomic, copy) NSData *serverFinderInfo;
@property (nonatomic, copy) NSArray<NSString *> *serverNames;
@property (nonatomic, copy) NSDictionary<NSString *, NSData *> *serverAttributes;
@property (nonatomic) NSUInteger openCount;
@property (nonatomic) uint64_t generation;
@end

@implementation AFPFSDoubleState
- (instancetype)init
{
    self = [super init];
    if (self) {
        _fd = -1;
    }
    return self;
}

- (NSData *)synthesizedHeader
{
    return AFPFSDoubleHeader(self.serverFinderInfo ?: [NSMutableData dataWithLength:32], self.serverNames ?: @[],
                             self.serverAttributes ?: @{}, self.forkLength, self.forkOffsetHint);
}

- (NSMutableData *)header
{
    if (!_header) {
        _header = [[self synthesizedHeader] mutableCopy];
    }
    return _header;
}

- (uint64_t)headerLength
{
    return _header ? _header.length : [self synthesizedHeader].length;
}

- (void)dropHeader
{
    if (!_headerDirty && !_staged) {
        _header = nil;
    }
}
@end

@implementation AFPFSMetadataStore {
    struct afp_volume *_vol;
    void (^_scheduler)(double, dispatch_block_t);
    NSMapTable<NSNumber *, AFPFSItem *> *_doubles;
    // xattrs we store locally since the server cannot keep them (either AFP 2, or xattr is too big)
    NSMutableDictionary<NSNumber *, NSDictionary<NSString *, NSData *> *> *_local;
    // lock on the desktop database since libafpclient doesn't lock it for us
    NSObject *_desktopLock;
}

- (instancetype)initWithVolume:(struct afp_volume *)vol scheduler:(void (^)(double, dispatch_block_t))scheduler
{
    self = [super init];
    if (self) {
        _vol = vol;
        _scheduler = [scheduler copy];
        _doubles = [NSMapTable strongToWeakObjectsMapTable];
        _local = [NSMutableDictionary dictionary];
        _desktopLock = [[NSObject alloc] init];
    }
    return self;
}

#pragma mark finder comments

/// Opens the volume's desktop database once. Returns NO when the server doesn't have one
- (BOOL)openDesktop
{
    if (_vol->dtrefnum > 0) {
        return YES;
    }
    if (_vol->no_desktop) {
        return NO;
    }
    int rc = afp_opendt(_vol, &_vol->dtrefnum);
    if (rc == kFPCallNotSupported) {
        _vol->no_desktop = 1;
    }
    return rc == kFPNoErr;
}

/// Returns the Finder coment as a bplist in kMDItemFinderComment format, or nil if no comment.
- (NSData *)commentOf:(AFPFSItem *)base
{
    unsigned int dirid = 0;
    char basename[AFPC_MAX_NAME_BYTES];
    if (!base.parent || AFPFSResolvePath(_vol, base.path, &dirid, basename) < 0) {
        return nil;
    }
    char buf[256];
    struct afp_comment comment = { .maxsize = sizeof(buf), .size = 0, .data = buf };
    int rc;
    @synchronized (_desktopLock) {
        if (![self openDesktop]) {
            return nil;
        }
        rc = afp_getcomment(_vol, dirid, basename, &comment);
    }
    if (rc != kFPNoErr || comment.size == 0) {
        return nil;
    }
    NSData *bytes = [NSData dataWithBytes:buf length:MIN(comment.size, sizeof(buf))];
    NSString *text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding]
                     ?: [[NSString alloc] initWithData:bytes encoding:AFPCEncoding.current];
    return text.length ? [NSPropertyListSerialization dataWithPropertyList:text format:NSPropertyListBinaryFormat_v1_0
                                                                   options:0 error:NULL] : nil;
}

/// Persists a kMDItemFinderComment value as the desktop database Finder comment. Pass nil to clear the comment.
- (void)setComment:(NSData *)value of:(AFPFSItem *)base
{
    [self writeComment:value of:base];
    if (_serverChanged) {
        _serverChanged();
    }
}

// writes the comment converting it to the server's encoding
- (void)writeComment:(NSData *)value of:(AFPFSItem *)base
{
    NSString *text = @"";
    if (value) {
        id plist = [NSPropertyListSerialization propertyListWithData:value options:0 format:NULL error:NULL];
        text = [plist isKindOfClass:[NSString class]] ? plist : @"";
    }
    // Allow conversion loss on AFP2 clients since that's preferable to 文字化け
    BOOL afp2 = _vol->server->using_version->av_number < 30;
    NSStringEncoding encoding = AFPCEncoding.current;
    NSData *bytes = [text dataUsingEncoding:encoding allowLossyConversion:afp2];
    if (!bytes) {
        encoding = NSUTF8StringEncoding;
        bytes = [text dataUsingEncoding:encoding];
    }
    while (bytes.length > kMaxComment && text.length) {
        text = [text substringToIndex:[text rangeOfComposedCharacterSequenceAtIndex:text.length - 1].location];
        bytes = [text dataUsingEncoding:encoding allowLossyConversion:afp2];
    }
    unsigned int dirid = 0;
    char basename[AFPC_MAX_NAME_BYTES];
    if (!base.parent || AFPFSResolvePath(_vol, base.path, &dirid, basename) < 0) {
        return;
    }
    @synchronized (_desktopLock) {
        if ([self openDesktop]) {
            afp_addcomment_sized(_vol, dirid, basename, bytes.bytes, bytes.length);
        }
    }
}

static AFPFSDoubleState *stateOf(AFPFSItem *item)
{
    return item.doubleState;
}

- (BOOL)serverKeepsXattrs:(AFPFSItem *)base
{
    return (_vol->attributes & kSupportsExtAttrs) && base.parent != nil;
}

#pragma mark server metadata

/// Returns the xattrs as names and values, sorted by name, including both server-side and local attrs
- (void)loadAttributesOf:(AFPFSItem *)base names:(NSArray **)namesOut values:(NSDictionary **)valuesOut
{
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    if ([self serverKeepsXattrs:base]) {
        const char *path = base.path.precomposedStringWithCanonicalMapping.UTF8String;
        int len = ml_listxattr(_vol, path, NULL, 0);
        if (len > 0) {
            char *list = malloc((size_t)len);
            len = list ? ml_listxattr(_vol, path, list, (size_t)len) : -ENOMEM;
            for (int i = 0; len > 0 && i < len; i += (int)strlen(list + i) + 1) {
                NSString *name = [NSString stringWithUTF8String:list + i];
                if (!name.length || isReservedXattrName(name)) {
                    continue;
                }
                int vlen = ml_getxattr(_vol, path, list + i, NULL, 0);
                if (vlen < 0) {
                    continue;
                }
                NSMutableData *v = [NSMutableData dataWithLength:(NSUInteger)vlen];
                if (vlen > 0 && ml_getxattr(_vol, path, list + i, v.mutableBytes, (size_t)vlen) < 0) {
                    continue;
                }
                values[name] = v;
            }
            free(list);
        }
    }
    // If we have a kMDItemFinderComment xattr, it takes precedence over the desktop database Finder comment
    if (!values[kCommentName]) {
        NSData *comment = [self commentOf:base];
        if (comment) {
            values[kCommentName] = comment;
        }
    }
    [values addEntriesFromDictionary:[self localAttributesOf:base]];
    *namesOut = [values.allKeys sortedArrayUsingSelector:@selector(compare:)];
    *valuesOut = values;
}

- (void)synthesize:(AFPFSDoubleState *)st base:(AFPFSItem *)base dirent:(const struct afp_dirent *)e
{
    NSMutableData *fi = (e->valid & kFPFinderInfoBit) ? [NSMutableData dataWithBytes:e->finderinfo length:32]
                                                      : [NSMutableData dataWithLength:32];
    // Some AFP servers (e.g. Mac OS X 10.1) replace unknown type/creator codes with question marks; clear that out since no type/creator is preferable to a nonsense one
    if (memcmp(fi.bytes, "????????", 8) == 0) {
        memset(fi.mutableBytes, 0, 8);
    }
    NSArray *names;
    NSDictionary *values;
    [self loadAttributesOf:base names:&names values:&values];
    st.serverFinderInfo = fi;
    st.serverNames = names;
    st.serverAttributes = values;
    st.forkLength = e->isdir ? 0 : e->resourcesize;
    st.headerDirty = NO;
    st.header = nil;
}

- (BOOL)hasMetadata:(AFPFSDoubleState *)st
{
    return !AFPFSFinderInfoIsEmpty(st.serverFinderInfo) || st.forkLength > 0 || st.serverNames.count > 0;
}

/// Returns whether the AppleDouble is busy
static BOOL isBusy(AFPFSDoubleState *st)
{
    return st.staged || st.headerDirty || st.openCount > 0;
}

- (AFPFSItem *)doubleFor:(AFPFSItem *)base dirent:(const struct afp_dirent *)e create:(BOOL)create error:(int *)err
{
    AFPFSItem *item;
    @synchronized (_doubles) {
        item = [_doubles objectForKey:@(base.itemID)];
        if (!item) {
            item = [[AFPFSItem alloc] initDoubleOf:base];
            item.doubleState = [[AFPFSDoubleState alloc] init];
            [_doubles setObject:item forKey:@(base.itemID)];
        }
    }
    @synchronized (item) {
        AFPFSDoubleState *st = stateOf(item);
        [item setParent:base.parent name:[@"._" stringByAppendingString:base.name]];
        if (!isBusy(st)) {
            [self synthesize:st base:base dirent:e];
        }
        if (create && !isBusy(st) && ![self hasMetadata:st]) {
            // If xnu is creating the AppleDouble, create it empty since xnu will write the header by itself
            if ([self stage:item upTo:0 empty:YES] < 0) {
                *err = EIO;
                return nil;
            }
        }
        // note: don't return enoent even with no metadata. if no metadata, return that the ._ exists but is empty. otherwise FSKit might remember that the ._ doesn't exist and not check it again in the future.
    }
    return item;
}

- (FSItemAttributes *)attributesOfDouble:(AFPFSItem *)item baseAttributes:(FSItemAttributes *)base
{
    FSItemAttributes *a = [[FSItemAttributes alloc] init];
    a.type = FSItemTypeFile;
    a.mode = S_IFREG | 0644;
    a.uid = base.uid;
    a.gid = base.gid;
    a.linkCount = 1;
    a.flags = 0;
    @synchronized (item) {
        a.size = [self sizeOf:stateOf(item)];
    }
    a.allocSize = (a.size + 4095) & ~(uint64_t)4095;
    a.fileID = item.itemID;
    a.parentID = base.parentID;
    a.modifyTime = base.modifyTime;
    a.changeTime = base.changeTime;
    a.accessTime = base.accessTime;
    a.birthTime = base.birthTime;
    a.addedTime = base.addedTime;
    a.backupTime = (struct timespec){ 0, 0 };
    a.supportsLimitedXAttrs = NO;
    a.inhibitKernelOffloadedIO = YES;
    return a;
}

- (uint64_t)sizeOf:(AFPFSDoubleState *)st
{
    if (st.staged) {
        struct stat sb;
        uint64_t size = fstat(st.fd, &sb) == 0 ? (uint64_t)sb.st_size : 0;
        return MAX(size, st.declaredEnd);
    }
    return st.headerLength + st.forkLength;
}

#pragma mark resource fork

- (int)openForkOf:(AFPFSItem *)item writable:(BOOL)writable
{
    AFPFSDoubleState *st = stateOf(item);
    if (st.fork && (!writable || st.forkWritable)) {
        return 0;
    }
    [self closeForkOf:item];
    // use the early fork if there is one
    struct afp_file_info *early = writable ? [item.base takeEarlyFork] : NULL;
    if (early) {
        st.fork = early;
        st.forkWritable = YES;
        return 0;
    }
    struct afp_file_info *fp = calloc(1, sizeof(*fp));
    if (!fp) {
        return -ENOMEM;
    }
    int ret;
    if (item.base.blind) {
        // this is a blind file (i.e. in a Drop Box) so do not perform a read or lookup
        free(fp);
        fp = NULL;
        ret = writable ? AFPFSOpenForkWriteOnly(_vol, item.base.path, YES, 0, &fp) : -EACCES;
    } else {
        fp->resource = AFP_META_RESOURCE;
        ret = AFPFSResolvePath(_vol, item.base.path, &fp->did, fp->basename);
        if (ret == 0) {
            ret = ll_open(_vol, NULL, writable ? O_RDWR : O_RDONLY, fp);
        }
        if (ret == -EACCES && writable) {
            // same as above, writable but not readable indicates a Drop Box file
            free(fp);
            fp = NULL;
            ret = AFPFSOpenForkWriteOnly(_vol, item.base.path, YES, 0, &fp);
        }
    }
    if (ret < 0) {
        free(fp);
        return ret;
    }
    st.fork = fp;
    st.forkWritable = writable;
    return 0;
}

- (void)closeForkOf:(AFPFSItem *)item
{
    AFPFSDoubleState *st = stateOf(item);
    if (st.fork) {
        afp_closefork(_vol, st.fork->forkid);
        remove_opened_fork(_vol, st.fork);
        free(st.fork);
        st.fork = NULL;
    }
}

- (int)readFork:(AFPFSItem *)item into:(char *)buf offset:(uint64_t)offset length:(size_t)length
      bytesRead:(size_t *)n
{
    *n = 0;
    int ret = [self openForkOf:item writable:NO];
    while (ret == 0 && *n < length) {
        int eof = 0;
        int got = ll_read(_vol, buf + *n, length - *n, (off_t)(offset + *n), stateOf(item).fork, &eof);
        if (got < 0) {
            ret = got;
            break;
        }
        *n += (size_t)got;
        if (eof || got == 0) {
            break;
        }
    }
    return ret;
}

#pragma mark i/o

- (int)read:(AFPFSItem *)item into:(void *)buf offset:(off_t)offset length:(size_t)length bytesRead:(size_t *)n
{
    @synchronized (item) {
        AFPFSDoubleState *st = stateOf(item);
        *n = 0;
        if (st.staged) {
            ssize_t got = pread(st.fd, buf, length, offset);
            if (got < 0) {
                return -errno;
            }
            uint64_t end = (uint64_t)offset + (uint64_t)got;
            if ((uint64_t)got < length && end < st.declaredEnd) {
                size_t fill = (size_t)MIN((uint64_t)(length - (size_t)got), st.declaredEnd - end);
                memset((char *)buf + got, 0, fill);
                got += (ssize_t)fill;
            }
            *n = (size_t)got;
            return 0;
        }
        uint64_t total = st.header.length + st.forkLength;
        if ((uint64_t)offset >= total) {
            return 0;
        }
        length = (size_t)MIN((uint64_t)length, total - (uint64_t)offset);
        size_t done = 0;
        if ((uint64_t)offset < st.header.length) {
            done = (size_t)MIN((uint64_t)length, st.header.length - (uint64_t)offset);
            memcpy(buf, (const char *)st.header.bytes + offset, done);
        }
        if (done < length) {
            size_t got = 0;
            uint64_t forkOffset = (uint64_t)offset + done - st.header.length;
            int ret = [self readFork:item into:(char *)buf + done offset:forkOffset length:length - done bytesRead:&got];
            // close the fork since pre-OS X won't let us delete or rename if the fork is open
            [self closeForkOf:item];
            if (ret < 0) {
                return ret;
            }
            done += got;
        }
        *n = done;
        return 0;
    }
}

/// Copies the current AppleDouble into a local temporary file to which reads/writes will be routed
- (int)stage:(AFPFSItem *)item upTo:(uint64_t)limit empty:(BOOL)empty
{
    AFPFSDoubleState *st = stateOf(item);
    if (st.staged) {
        return 0;
    }
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/afpfs-double-XXXXXX", NSTemporaryDirectory().fileSystemRepresentation);
    int fd = mkstemp(path);
    if (fd < 0) {
        return -errno;
    }
    // only descriptor is needed
    unlink(path);

    if (!empty) {
        if (pwrite(fd, st.header.bytes, st.header.length, 0) != (ssize_t)st.header.length) {
            close(fd);
            return -EIO;
        }
        uint64_t want = MIN(limit, st.forkLength);
        char *chunk = malloc(kCopyChunk);
        uint64_t copied = 0;
        int ret = chunk ? 0 : -ENOMEM;
        while (ret == 0 && copied < want) {
            size_t got = 0;
            ret = [self readFork:item into:chunk offset:copied length:(size_t)MIN((uint64_t)kCopyChunk, want - copied)
                       bytesRead:&got];
            if (ret == 0 && got == 0) {
                break;
            }
            if (ret == 0 && pwrite(fd, chunk, got, (off_t)(st.header.length + copied)) != (ssize_t)got) {
                ret = -EIO;
            }
            copied += got;
        }
        free(chunk);
        [self closeForkOf:item];
        if (ret < 0) {
            close(fd);
            return ret;
        }
    }
    st.fd = fd;
    st.staged = YES;
    st.headerDirty = NO;
    st.declaredEnd = empty ? 0 : st.header.length + MIN(st.forkLength, limit);
    return 0;
}

- (void)scheduleCommit:(AFPFSItem *)item
{
    AFPFSDoubleState *st = stateOf(item);
    uint64_t generation = ++st.generation;
    __weak AFPFSMetadataStore *weakSelf = self;
    _scheduler(kCommitDelay, ^{
        AFPFSMetadataStore *store = weakSelf;
        @synchronized (item) {
            if (store && stateOf(item).generation == generation && stateOf(item).openCount == 0) {
                [store commit:item force:NO];
            }
        }
    });
}

- (int)write:(AFPFSItem *)item data:(NSData *)data offset:(off_t)offset
{
    @synchronized (item) {
        AFPFSDoubleState *st = stateOf(item);
        os_log_debug(md_log(), "write %{public}@ off=%lld len=%lu staged=%d open=%lu", item.name, offset,
               (unsigned long)data.length, st.staged, (unsigned long)st.openCount);
        if (!st.staged && (uint64_t)offset + data.length <= st.header.length) {
            [st.header replaceBytesInRange:NSMakeRange((NSUInteger)offset, data.length) withBytes:data.bytes];
            st.headerDirty = YES;
        } else {
            int ret = [self stage:item upTo:UINT64_MAX empty:NO];
            if (ret < 0) {
                return ret;
            }
            if (pwrite(st.fd, data.bytes, data.length, offset) != (ssize_t)data.length) {
                return -errno;
            }
            st.dirty = YES;
            if (offset < 0x32) {
                [self updateDeclaredEnd:st];
            }
        }
        [self scheduleCommit:item];
        return 0;
    }
}

- (int)truncate:(AFPFSItem *)item size:(uint64_t)size
{
    @synchronized (item) {
        AFPFSDoubleState *st = stateOf(item);
        os_log_debug(md_log(), "truncate %{public}@ size=%llu staged=%d", item.name, size, st.staged);
        if (!st.staged && size == st.header.length + st.forkLength) {
            return 0;
        }
        uint64_t keep = size > st.header.length ? size - st.header.length : 0;
        int ret = [self stage:item upTo:keep empty:NO];
        if (ret < 0) {
            return ret;
        }
        if (ftruncate(st.fd, (off_t)size) < 0) {
            return -errno;
        }
        st.declaredEnd = MIN(st.declaredEnd, size);
        st.dirty = YES;
        [self scheduleCommit:item];
        return 0;
    }
}

- (void)updateDeclaredEnd:(AFPFSDoubleState *)st
{
    NSMutableData *start = [NSMutableData dataWithLength:0x32];
    if (pread(st.fd, start.mutableBytes, 0x32, 0) != 0x32) {
        return;
    }
    uint64_t forkOffset = AFPFSDoubleHeaderLength(start);
    const uint8_t *p = start.bytes;
    uint16_t count = OSReadBigInt16(p, 24);
    uint64_t forkLength = 0;
    for (uint16_t i = 0; forkOffset && i < count && 26 + i * 12 + 12 <= 0x32; i++) {
        if (OSReadBigInt32(p, 26 + i * 12) == 2) {
            forkLength = OSReadBigInt32(p, 34 + i * 12);
        }
    }
    st.declaredEnd = forkOffset ? forkOffset + forkLength : 0;
}

- (void)opened:(AFPFSItem *)item
{
    os_log_debug(md_log(), "opened %{public}@", item.name);
    @synchronized (item) {
        stateOf(item).openCount++;
    }
}

- (void)closed:(AFPFSItem *)item
{
    os_log_debug(md_log(), "closed %{public}@", item.name);
    @synchronized (item) {
        AFPFSDoubleState *st = stateOf(item);
        st.openCount = 0;
        if (st.staged || st.headerDirty) {
            [self scheduleCommit:item];
        } else {
            [st dropHeader];
        }
    }
}

#pragma mark commit

- (int)setFinderInfo:(NSData *)fi of:(AFPFSItem *)base
{
    unsigned int dirid;
    char basename[AFPC_MAX_NAME_BYTES];
    int ret = AFPFSResolvePath(_vol, base.path, &dirid, basename);
    if (ret < 0) {
        return ret;
    }
    struct afp_dirent e;
    memset(&e, 0, sizeof(e));
    memcpy(e.finderinfo, fi.bytes, 32);
    switch (afp_setfiledirparms(_vol, dirid, basename, kFPFinderInfoBit, &e)) {
    case kFPNoErr:
        return 0;
    case kFPAccessDenied:
        return -EACCES;
    case kFPObjectNotFound:
        return -ENOENT;
    default:
        return -EIO;
    }
}

- (BOOL)modificationDateOf:(AFPFSItem *)base into:(struct afp_dirent *)e
{
    unsigned int dirid;
    char basename[AFPC_MAX_NAME_BYTES];
    memset(e, 0, sizeof(*e));
    return AFPFSResolvePath(_vol, base.path, &dirid, basename) == 0
           && afp_getfiledirparms(_vol, dirid, kFPModDateBit, kFPModDateBit, basename, e) == kFPNoErr
           && (e->valid & kFPModDateBit);
}

- (void)restoreModificationDate:(const struct afp_dirent *)e of:(AFPFSItem *)base
{
    unsigned int dirid;
    char basename[AFPC_MAX_NAME_BYTES];
    if (AFPFSResolvePath(_vol, base.path, &dirid, basename) == 0) {
        afp_setfiledirparms(_vol, dirid, basename, kFPModDateBit, e);
    }
}

- (int)writeFork:(AFPFSItem *)item from:(int)fd offset:(uint64_t)offset length:(uint64_t)length
{
    if (item.base.isDirectory) {
        if (length) {
            os_log_error(md_log(), "discarding attempt to write resource fork for directory %{private}@", item.base.path);
        }
        return 0;
    }
    int ret = [self openForkOf:item writable:YES];
    if (ret < 0) {
        return ret;
    }
    AFPFSDoubleState *st = stateOf(item);
    int rc = ll_setfork_size(_vol, st.fork->forkid, 1, length);
    if (rc) {
        return -rc;
    }
    char *chunk = malloc(kCopyChunk);
    if (!chunk) {
        return -ENOMEM;
    }
    for (uint64_t done = 0; ret == 0 && done < length; ) {
        size_t want = (size_t)MIN((uint64_t)kCopyChunk, length - done);
        ssize_t got = pread(fd, chunk, want, (off_t)(offset + done));
        if (got <= 0) {
            ret = -EIO;
            break;
        }
        size_t written = 0;
        ret = ll_write(_vol, chunk, (size_t)got, (off_t)done, st.fork, &written);
        if (ret == 0 && written != (size_t)got) {
            ret = -EIO;
        }
        done += (uint64_t)got;
    }
    free(chunk);
    // close the fork so other clients can open
    [self closeForkOf:item];
    return ret;
}

/// Our local copies of xattrs the server isn't capable of storing
- (NSDictionary<NSString *, NSData *> *)localAttributesOf:(AFPFSItem *)base
{
    @synchronized (_local) {
        return _local[@(base.itemID)] ?: @{};
    }
}

- (void)setLocal:(NSString *)name value:(nullable NSData *)value of:(AFPFSItem *)base
{
    @synchronized (_local) {
        NSMutableDictionary *local = [_local[@(base.itemID)] mutableCopy] ?: [NSMutableDictionary dictionary];
        local[name] = value;
        _local[@(base.itemID)] = local.count ? local : nil;
    }
}

- (void)forgetLocalAttributesOf:(AFPFSItem *)base
{
    @synchronized (_local) {
        [_local removeObjectForKey:@(base.itemID)];
    }
}

- (void)setAttribute:(NSString *)name value:(NSData *)value of:(AFPFSItem *)base
{
    if ([name isEqualToString:kCommentName]) {
        [self setComment:value of:base];
    }
    BOOL stored = [self serverKeepsXattrs:base] && value.length <= kMaxServerXattr
                  && ml_setxattr(_vol, base.path.precomposedStringWithCanonicalMapping.UTF8String, name.UTF8String,
                                 value.bytes, value.length, 0) == 0;
    [self setLocal:name value:stored ? nil : value of:base];
}

- (void)removeAttribute:(NSString *)name of:(AFPFSItem *)base
{
    if ([name isEqualToString:kCommentName]) {
        [self setComment:nil of:base];
    }
    if ([self localAttributesOf:base][name]) {
        [self setLocal:name value:nil of:base];
    } else if ([self serverKeepsXattrs:base]) {
        ml_removexattr(_vol, base.path.precomposedStringWithCanonicalMapping.UTF8String, name.UTF8String);
    }
}

- (void)dropStaging:(AFPFSDoubleState *)st
{
    if (st.fd >= 0) {
        close(st.fd);
    }
    st.fd = -1;
    st.staged = NO;
    st.dirty = NO;
    st.headerDirty = NO;
    st.declaredEnd = 0;
}

/// Writes AppleDouble changes back to the server. Must be called while holding @synchronized(item).
- (int)commit:(AFPFSItem *)item force:(BOOL)force
{
    int ret = [self writeCommit:item force:force];
    if (_serverChanged) {
        _serverChanged();
    }
    return ret;
}

- (int)writeCommit:(AFPFSItem *)item force:(BOOL)force
{
    AFPFSDoubleState *st = stateOf(item);
    AFPFSItem *base = item.base;
    AFPFSDoubleContents *c = nil;

    if (st.staged) {
        struct stat sb;
        if (fstat(st.fd, &sb) < 0) {
            return -errno;
        }
        if (sb.st_size == 0) {
            // created but never written
            if (!force) {
                [self dropStaging:st];
            }
            return 0;
        }
        NSMutableData *start = [NSMutableData dataWithLength:0x32];
        if (pread(st.fd, start.mutableBytes, 0x32, 0) != 0x32) {
            os_log_error(md_log(), "unreadable AppleDouble file for %{private}@", base.path);
            return -EIO;
        }
        uint64_t headerLength = AFPFSDoubleHeaderLength(start);
        uint64_t fileLength = MAX((uint64_t)sb.st_size, st.declaredEnd);
        if (!headerLength || headerLength > fileLength || headerLength > 64 * 1024 * 1024) {
            os_log_error(md_log(), "not an AppleDouble file for %{private}@", base.path);
            return -EINVAL;
        }
        // zero any parts of the header xnu didn't write
        NSMutableData *header = [NSMutableData dataWithLength:(NSUInteger)headerLength];
        size_t have = (size_t)MIN(headerLength, (uint64_t)sb.st_size);
        if (pread(st.fd, header.mutableBytes, have, 0) != (ssize_t)have) {
            return -EIO;
        }
        c = AFPFSParseDouble(header, fileLength);
    } else if (st.headerDirty) {
        c = AFPFSParseDouble(st.header, st.header.length + st.forkLength);
    } else {
        return 0;
    }
    if (!c) {
        os_log_error(md_log(), "unparsable AppleDouble file for %{private}@", base.path);
        return -EINVAL;
    }
    os_log_debug(md_log(), "commit %{public}@ force=%d staged=%d open=%lu fork at 0x%llx len %llu", item.name, force,
           st.staged, (unsigned long)st.openCount, c.forkOffset, c.forkLength);

    int ret = 0;
    NSData *finderInfo = c.finderInfo;
    if (![c.finderInfo isEqualToData:st.serverFinderInfo]) {
        ret = [self setFinderInfo:c.finderInfo of:base];
        if (ret == -EACCES) {
            // we couldn't set the FinderInfo. this is normal pre-10.2 in a Drop Box.
            // early fork can still be written, so we won't lose the resource data at least,
            // but type/creator are hosed.
            // if you run into this problem, stop using a drop box please.....
            os_log_error(md_log(), "the server refused FinderInfo for %{private}@", base.path);
            finderInfo = st.serverFinderInfo;
            ret = 0;
        }
    }
    if (ret == 0 && st.staged) {
        // write the desired modification date, since the server probably updated the date itself when we wrote the fork
        struct afp_dirent before;
        BOOL haveDate = [self modificationDateOf:base into:&before];
        ret = [self writeFork:item from:st.fd offset:c.forkOffset length:c.forkLength];
        if (ret == 0 && haveDate) {
            [self restoreModificationDate:&before of:base];
        }
    }
    if (ret == 0) {
        for (NSString *name in c.attributeNames) {
            if (isReservedXattrName(name)) {
                continue;
            }
            if (![st.serverAttributes[name] isEqualToData:c.attributes[name]]) {
                [self setAttribute:name value:c.attributes[name] of:base];
            }
        }
        for (NSString *name in st.serverNames) {
            if (!c.attributes[name]) {
                [self removeAttribute:name of:base];
            }
        }
    }
    if (ret < 0) {
        os_log_error(md_log(), "commit of %{private}@ failed: %d", base.path, ret);
        if (ret == -ENOENT || ret == -EACCES || ret == -EPERM) {
            // couldn't write the fork (file disappeared, server didn't allow it, etc.), so drop it from our staging
            [self dropStaging:st];
        }
        return ret;
    }

    os_log_debug(md_log(), "committed %{private}@: fork %llu, %lu xattrs", base.path, c.forkLength,
                 (unsigned long)c.attributeNames.count);
    // update our view of what the server has
    st.serverFinderInfo = finderInfo;
    st.serverNames = c.attributeNames;
    st.serverAttributes = c.attributes;
    if (!force || st.openCount == 0) {
        [self dropStaging:st];
        st.forkLength = base.isDirectory ? 0 : c.forkLength;
        st.forkOffsetHint = c.forkOffset;
        st.header = nil;
    }
    return 0;
}

- (AFPFSItem *)existingDoubleOf:(AFPFSItem *)base
{
    @synchronized (_doubles) {
        return [_doubles objectForKey:@(base.itemID)];
    }
}

- (void)releaseForksOf:(AFPFSItem *)base
{
    AFPFSItem *item;
    @synchronized (_doubles) {
        item = [_doubles objectForKey:@(base.itemID)];
    }
    if (item) {
        @synchronized (item) {
            [self closeForkOf:item];
        }
    }
}

- (void)commitAll
{
    NSArray *items;
    @synchronized (_doubles) {
        items = _doubles.objectEnumerator.allObjects;
    }
    for (AFPFSItem *item in items) {
        @synchronized (item) {
            [self commit:item force:YES];
        }
    }
}

- (int)removeMetadataOf:(AFPFSItem *)item
{
    int ret = [self writeRemovalOf:item];
    if (_serverChanged) {
        _serverChanged();
    }
    return ret;
}

- (int)writeRemovalOf:(AFPFSItem *)item
{
    @synchronized (item) {
        AFPFSDoubleState *st = stateOf(item);
        AFPFSItem *base = item.base;
        [self dropStaging:st];
        int ret = 0;
        if (!AFPFSFinderInfoIsEmpty(st.serverFinderInfo)) {
            ret = [self setFinderInfo:[NSMutableData dataWithLength:32] of:base];
        }
        if (ret == 0 && st.forkLength > 0) {
            ret = ml_truncateresourcefork(_vol, base.path.precomposedStringWithCanonicalMapping.UTF8String, 0);
        }
        for (NSString *name in st.serverNames) {
            [self removeAttribute:name of:base];
        }
        if (ret == -ENOENT) {
            ret = 0;
        }
        st.serverFinderInfo = [NSMutableData dataWithLength:32];
        st.serverNames = @[];
        st.serverAttributes = @{};
        st.forkLength = 0;
        st.header = [AFPFSDoubleHeader(st.serverFinderInfo, @[], @{}, 0, st.forkOffsetHint) mutableCopy];
        return ret;
    }
}

- (void)reclaim:(AFPFSItem *)item
{
    @synchronized (item) {
        AFPFSDoubleState *st = stateOf(item);
        st.openCount = 0;
        [self commit:item force:NO];
        [self dropStaging:st];
        [self closeForkOf:item];
    }
    @synchronized (_doubles) {
        if ([_doubles objectForKey:@(item.base.itemID)] == item) {
            [_doubles removeObjectForKey:@(item.base.itemID)];
        }
    }
}

@end
