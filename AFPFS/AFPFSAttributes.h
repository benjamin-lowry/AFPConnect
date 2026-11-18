//
//  AFPFSAttributes.h
//  AFPFS
//
//  Created by Benjamin Lowry on 2026-11-06.
//

#import <FSKit/FSKit.h>

#import "AFPCInternal.h"
#import "AFPCSession.h"

NS_ASSUME_NONNULL_BEGIN

// afp file and directory attribute bits
enum {
    AFPFSAttrInvisible = 0x0001,
    AFPFSAttrWriteInhibit = 0x0020,
    AFPFSAttrRenameInhibit = 0x0080,
    AFPFSAttrDeleteInhibit = 0x0100,
    AFPFSAttrSetClear = 0x8000,
};

// invisible flag in FinderInfo fdFlags (bytes 8 and 9)
enum { AFPFSFinderInvisible = 0x4000 };

FSItemType AFPFSItemTypeOfDirent(const struct afp_dirent *e);

/// Returns the FSItemAttributes corresponding to the dirent e.
FSItemAttributes *AFPFSAttributesFromDirent(struct afp_volume *vol, const struct afp_dirent *e, BOOL isRoot,
                                            AFPCSession *session, const struct afp_dirent *_Nullable parent);

/// Whether the session is allowed to see the files in dir (YES if the server did not specify)
BOOL AFPFSCanSeeFiles(const struct afp_dirent *dir);

/// Whether a file's permissions cascade from its parent directory's permissions (i.e. no unix privileges)
BOOL AFPFSNeedsParentRights(const struct afp_dirent *e);

/// Converts path from UTF-8 to dirid and AFP-encoded basename (needed as input to afp\_getfiledirparms etc.)
/// 0 on success, negative errno on failure. Can fail because the path is too long, the path does not exist, or the path contains an invalid character
int AFPFSResolvePath(struct afp_volume *vol, NSString *path, unsigned int *dirid,
                     char basename[_Nonnull AFPC_MAX_NAME_BYTES]);

/// Open the given fork (data or resource) for write-only access without performing a file lookup. Use this to write to files in a non-readable location (e.g. a Drop Box) where ll\_open wouldn't work due to lack of read access. 0 on success, negative errno on failure. Caller is responsible for calling ml\_close/afp\_closefork and freeing \*fork.
int AFPFSOpenForkWriteOnly(struct afp_volume *vol, NSString *path, BOOL resource, uint64_t size,
                           struct afp_file_info *_Nullable *_Nonnull fork);

/// Sets the creation date (as a server time). 0 on success, negative errno on failure.
int AFPFSSetCreationDate(struct afp_volume *vol, NSString *path, time_t serverTime);

/// Applies birth time, UF\_HIDDEN, and UF\_IMMUTABLE, which ml\_setattr does not. 0 on success, negative errno on failure.
int AFPFSApplyMetadata(struct afp_volume *vol, NSString *path, FSItemSetAttributesRequest *req,
                       AFPCSession *session);

NS_ASSUME_NONNULL_END
