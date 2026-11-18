//
//  AFPFSAttributes.m
//  AFPFS
//
//  Created by Benjamin Lowry on 2026-11-06.
//
//  This code handles file attributes (permission bits, metadata, etc.)

#import "AFPFSAttributes.h"

#import <sys/stat.h>

static const uint16_t kLockedBits = AFPFSAttrWriteInhibit | AFPFSAttrRenameInhibit | AFPFSAttrDeleteInhibit;

/// Returns YES/NO whether the dirent e is a symlink
static BOOL isSymlink(const struct afp_dirent *e)
{
    if (e->isdir) {
        return NO;
    }
    if ((e->valid & kFPUnixPrivsBit) && S_ISLNK(e->unixprivs.permissions)) {
        return YES;
    }
    return (e->valid & kFPFinderInfoBit) && memcmp(e->finderinfo, ML_SYMLINK_FINDERINFO, 8) == 0;
}

/// Returns YES/NO whether the dirent e is invisible in Finder
static BOOL finderInvisible(const struct afp_dirent *e)
{
    return (e->valid & kFPFinderInfoBit) && (OSReadBigInt16(e->finderinfo, 8) & AFPFSFinderInvisible);
}

/// Returns the FSItemType (directory, symlink, or file) of the dirent e
FSItemType AFPFSItemTypeOfDirent(const struct afp_dirent *e)
{
    if (e->isdir) {
        return FSItemTypeDirectory;
    }
    return isSymlink(e) ? FSItemTypeSymlink : FSItemTypeFile;
}

/// Converts the AFP access rights flag rights to Unix permission bits
// used by modeOf to get file modes
static mode_t permissionsOf(uint32_t rights, BOOL isdir, BOOL unixPrivs)
{
    mode_t m = 0;
    if (rights & 0x02) {
        m |= 4;
    }
    if (rights & 0x04) {
        m |= 2;
    }
    if (unixPrivs ? (rights & 0x01) : (isdir && (rights & 0x07))) {
        m |= 1;
    }
    return m;
}

static BOOL hasRights(const struct afp_dirent *e)
{
    return (e->valid & kFPUnixPrivsBit) || (e->isdir && (e->valid & kFPAccessRightsBit));
}

BOOL AFPFSCanSeeFiles(const struct afp_dirent *dir)
{
    if (!hasRights(dir)) {
        return YES;
    }
    uint32_t rights = dir->unixprivs.ua_permissions;
    return (rights & kUserIsOwner) || ((rights >> 24) & 0x02);
}

BOOL AFPFSNeedsParentRights(const struct afp_dirent *e)
{
    return !e->isdir && !(e->valid & kFPUnixPrivsBit);
}

/// Returns the unix file mode we have on the dirent e, either the owner privileges (if we're the file owner) or the session privileges (if we aren't)
static mode_t modeOf(const struct afp_dirent *e, const struct afp_dirent *parent)
{
    mode_t mode;
    uint32_t rights;
    if ((e->valid & kFPUnixPrivsBit) && e->unixprivs.permissions) {
        mode = (e->isdir ? S_IFDIR : S_IFREG) | (e->unixprivs.permissions & 01777);
        rights = e->unixprivs.ua_permissions;
        if (rights & kUserIsOwner) {
            return mode;
        }
        return (mode & ~(mode_t)S_IRWXU) | (permissionsOf(rights >> 24, e->isdir, YES) << 6);
    }
    // No unix privileges (either disabled on the server side or afp 2.x which doesn't implement them)
    if (e->isdir) {
        if (!hasRights(e)) {
            return S_IFDIR | 0755;
        }
        rights = e->unixprivs.ua_permissions;
        mode_t owner = permissionsOf((rights & kUserIsOwner) ? rights : rights >> 24, YES, NO);
        return S_IFDIR | (owner << 6) | (permissionsOf(rights >> 8, YES, NO) << 3) | permissionsOf(rights >> 16, YES, NO);
    }
    if (!parent || !hasRights(parent) || (parent->unixprivs.ua_permissions & kUserIsOwner)) {
        return S_IFREG | 0644;
    }
    return S_IFREG | (permissionsOf(parent->unixprivs.ua_permissions >> 24, NO, NO) << 6) | 0044;
}

FSItemAttributes *AFPFSAttributesFromDirent(struct afp_volume *vol, const struct afp_dirent *e, BOOL isRoot,
                                            AFPCSession *session, const struct afp_dirent *parent)
{
    FSItemAttributes *a = [[FSItemAttributes alloc] init];
    FSItemType type = AFPFSItemTypeOfDirent(e);
    a.type = type;

    mode_t mode = modeOf(e, parent);
    if (type == FSItemTypeSymlink) {
        mode = S_IFLNK | 0755;
    }
    a.mode = mode;

    uid_t uid = getuid();
    gid_t gid = getgid();
    if (e->valid & (kFPUnixPrivsBit | kFPOwnerIDBit)) {
        unsigned int u = e->unixprivs.uid, g = e->unixprivs.gid;
        if (translate_uidgid_to_client(vol, &u, &g) == 0) {
            uid = u;
            gid = g;
        }
    }
    a.uid = uid;
    a.gid = gid;

    uint32_t flags = 0;
    if ((e->attributes & AFPFSAttrInvisible) || finderInvisible(e)) {
        flags |= UF_HIDDEN;
    }
    if (!e->isdir && (e->attributes & kLockedBits)) {
        flags |= UF_IMMUTABLE;
    }
    a.flags = flags;

    if (e->isdir) {
        uint32_t links = (uint32_t)e->offspring + 2;
        a.linkCount = links > UINT16_MAX ? 1 : links;
        a.size = (uint64_t)e->offspring * 34 + 24;
    } else {
        a.linkCount = 1;
        a.size = e->size;
    }
    
    a.allocSize = (a.size + 4095) & ~(uint64_t)4095;

    a.fileID = isRoot ? FSItemIDRootDirectory : e->cnid;
    a.parentID = isRoot ? FSItemIDParentOfRoot : (e->parent_did ?: FSItemIDParentOfRoot);

    struct timespec created = [session localTimeFromServer:afp_dirent_time(vol, e, kFPCreateDateBit, e->create_ns)];
    struct timespec modified = [session localTimeFromServer:afp_dirent_time(vol, e, kFPModDateBit, e->mod_ns)];
    a.birthTime = created;
    a.modifyTime = modified;
    // AFP doesn't save change/access time, so use the modified timestamp for them
    a.changeTime = modified;
    a.accessTime = modified;
    a.addedTime = created;
    a.backupTime = (struct timespec){ 0, 0 };

    // Tell FSKit we don't support xattrs, so attribute writes will go to the AppleDouble files
    a.supportsLimitedXAttrs = NO;
    
    a.inhibitKernelOffloadedIO = YES;
    return a;
}

int AFPFSOpenForkWriteOnly(struct afp_volume *vol, NSString *path, BOOL resource, uint64_t size,
                           struct afp_file_info **fork)
{
    struct afp_file_info *fp = calloc(1, sizeof(*fp));
    if (!fp) {
        return -ENOMEM;
    }
    unsigned int dirid;
    int ret = AFPFSResolvePath(vol, path, &dirid, fp->basename);
    if (ret < 0) {
        free(fp);
        return ret;
    }
    fp->did = dirid;
    fp->resource = resource ? AFP_META_RESOURCE : 0;
    fp->writable = 1;
    fp->size = size;
    pthread_rwlock_rdlock(&vol->open_lock);
    int rc = afp_openfork(vol, resource ? 1 : 0, fp->did, AFP_OPENFORK_ALLOWWRITE, 0, fp->basename, fp);
    if (rc == kFPNoErr) {
        add_opened_fork(vol, fp);
    }
    pthread_rwlock_unlock(&vol->open_lock);
    if ((ret = ll_openfork_errno(rc)) != 0) {
        free(fp);
        return -ret;
    }
    *fork = fp;
    return 0;
}

int AFPFSResolvePath(struct afp_volume *vol, NSString *path, unsigned int *dirid,
                     char basename[AFPC_MAX_NAME_BYTES])
{
    const char *unixPath = path.precomposedStringWithCanonicalMapping.UTF8String;
    if (!unixPath) {
        return -EINVAL;
    }
    size_t len = strlen(unixPath) * 4 + 1;
    char *converted = malloc(len);
    if (!converted) {
        return -ENOMEM;
    }
    int ret = 0;
    if (convert_path_to_afp(vol->path_encoding, converted, unixPath, (int)len) < 0) {
        // path contains a non-AFP 2-compatible character
        ret = -EINVAL;
    } else if (invalid_filename(vol, converted)) {
        ret = -ENAMETOOLONG;
    } else if (get_dirid(vol, converted, basename, dirid) < 0) {
        ret = -ENOENT;
    } else if (vol->server->using_version->av_number < 30 && converted[0] == '/' && converted[1] == '\0') {
        // this path is the volume root and we're on AFP 2
        // (on AFP 2 the volume root is read as the volume name)
        snprintf(basename, AFPC_MAX_NAME_BYTES, "%s", vol->volume_name);
        *dirid = 1;
    }
    free(converted);
    return ret;
}

static int setParams(struct afp_volume *vol, unsigned int dirid, const char *basename,
                     unsigned short bitmap, const struct afp_dirent *e)
{
    switch (afp_setfiledirparms(vol, dirid, basename, bitmap, e)) {
    case kFPNoErr:
        return 0;
    case kFPAccessDenied:
        return -EACCES;
    case kFPObjectNotFound:
        return -ENOENT;
    case kFPVolLocked:
        return -EROFS;
    default:
        return -EIO;
    }
}

int AFPFSSetCreationDate(struct afp_volume *vol, NSString *path, time_t serverTime)
{
    unsigned int dirid;
    char basename[AFPC_MAX_NAME_BYTES];
    int ret = AFPFSResolvePath(vol, path, &dirid, basename);
    if (ret < 0) {
        return ret;
    }
    struct afp_dirent e;
    memset(&e, 0, sizeof(e));
    e.create_ns = afp_ns_from_sec(serverTime);
    return setParams(vol, dirid, basename, kFPCreateDateBit, &e);
}

int AFPFSApplyMetadata(struct afp_volume *vol, NSString *path, FSItemSetAttributesRequest *req,
                       AFPCSession *session)
{
    BOOL birth = [req isValid:FSItemAttributeBirthTime];
    BOOL flags = [req isValid:FSItemAttributeFlags];
    if (!birth && !flags) {
        return 0;
    }

    unsigned int dirid;
    char basename[AFPC_MAX_NAME_BYTES];
    int ret = AFPFSResolvePath(vol, path, &dirid, basename);
    if (ret < 0) {
        return ret;
    }

    if (birth) {
        struct afp_dirent e;
        memset(&e, 0, sizeof(e));
        e.create_ns = afp_ns_from_sec([session serverTimeFromLocal:req.birthTime.tv_sec]) + req.birthTime.tv_nsec;
        if ((ret = setParams(vol, dirid, basename, kFPCreateDateBit, &e)) < 0) {
            return ret;
        }
        req.consumedAttributes |= FSItemAttributeBirthTime;
    }

    if (flags) {
        struct afp_dirent cur;
        memset(&cur, 0, sizeof(cur));
        int rc = afp_getfiledirparms(vol, dirid, kFPAttributeBit | kFPFinderInfoBit,
                                     kFPAttributeBit | kFPFinderInfoBit, basename, &cur);
        if (rc != kFPNoErr) {
            return rc == kFPObjectNotFound ? -ENOENT : -EIO;
        }

        BOOL hidden = (req.flags & UF_HIDDEN) != 0;
        BOOL locked = (req.flags & (UF_IMMUTABLE | SF_IMMUTABLE)) != 0 && !cur.isdir;
        uint16_t set = 0, clear = 0;
        if (hidden != ((cur.attributes & AFPFSAttrInvisible) != 0)) {
            *(hidden ? &set : &clear) |= AFPFSAttrInvisible;
        }
        if (!cur.isdir && locked != ((cur.attributes & kLockedBits) == kLockedBits)) {
            *(locked ? &set : &clear) |= kLockedBits;
        }

        struct afp_dirent e;
        memset(&e, 0, sizeof(e));
        if (set) {
            e.attributes = AFPFSAttrSetClear | set;
            if ((ret = setParams(vol, dirid, basename, kFPAttributeBit, &e)) < 0) {
                return ret;
            }
        }
        if (clear) {
            e.attributes = clear;
            if ((ret = setParams(vol, dirid, basename, kFPAttributeBit, &e)) < 0) {
                return ret;
            }
        }

        // keep the FinderInfo invisible flag synchronized with the metadata,
        // since it's what the Finder uses to determine whether the file is invisible
        if ((cur.valid & kFPFinderInfoBit) && hidden != finderInvisible(&cur)) {
            uint16_t fdFlags = OSReadBigInt16(cur.finderinfo, 8);
            fdFlags = hidden ? (fdFlags | AFPFSFinderInvisible) : (fdFlags & ~AFPFSFinderInvisible);
            OSWriteBigInt16(cur.finderinfo, 8, fdFlags);
            if ((ret = setParams(vol, dirid, basename, kFPFinderInfoBit, &cur)) < 0) {
                return ret;
            }
        }
        req.consumedAttributes |= FSItemAttributeFlags;
    }
    return 0;
}
