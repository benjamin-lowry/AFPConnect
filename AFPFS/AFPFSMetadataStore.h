//
//  AFPFSMetadataStore.h
//  AFPFS
//
//  Created by Benjamin Lowry on 2026-11-07.
//
//  Provides files' xattrs (and FinderInfo and resource fork by extension) to the host
//  by generating a "fake" AppleDouble (._[filename] file) for XNU to parse xattrs from
//  and write modified xattrs back to.
//  FSKit is supposed to have real support for xattrs, but in my testing
//  there seems to be an undocumented 256KiB limit on the size of an xattr.
//  So we have to do this crap instead

#import <FSKit/FSKit.h>

#import "AFPCInternal.h"
#import "AFPFSItem.h"

NS_ASSUME_NONNULL_BEGIN

@interface AFPFSMetadataStore : NSObject

- (instancetype)initWithVolume:(struct afp_volume *)vol
                     scheduler:(void (^)(double delay, dispatch_block_t block))scheduler;

/// Called when a file has changed on the server
@property (copy, nullable) void (^serverChanged)(void);

/// Returns the AppleDouble .\_ item for the given base item and its dirent. The double will be empty if base has no xattrs/FinderInfo/resource fork.
- (nullable AFPFSItem *)doubleFor:(AFPFSItem *)base dirent:(const struct afp_dirent *)e
                           create:(BOOL)create error:(int *)err;

/// Returns the FSItemAttributes for the given AppleDouble.
- (FSItemAttributes *)attributesOfDouble:(AFPFSItem *)item baseAttributes:(FSItemAttributes *)base;

- (int)read:(AFPFSItem *)item into:(void *)buf offset:(off_t)offset length:(size_t)length
   bytesRead:(size_t *)n;
- (int)write:(AFPFSItem *)item data:(NSData *)data offset:(off_t)offset;
- (int)truncate:(AFPFSItem *)item size:(uint64_t)size;

- (void)opened:(AFPFSItem *)item;
- (void)closed:(AFPFSItem *)item;

/// Clear metadata for the given item
- (int)removeMetadataOf:(AFPFSItem *)item;

/// The AppleDouble item the kernel may know for base, if any
- (nullable AFPFSItem *)existingDoubleOf:(AFPFSItem *)base;

/// Close any resource fork this AppleDouble has a handle on. Called before renaming/deleting base, since pre-OS X AFP servers will deny both operations if there is an outstanding handle on the fork
- (void)releaseForksOf:(AFPFSItem *)base;

/// Forget the xattrs we're caching here. Call when base no longer exists on the server
- (void)forgetLocalAttributesOf:(AFPFSItem *)base;

/// Force a push of pending changes now
- (void)commitAll;

- (void)reclaim:(AFPFSItem *)item;

@end

NS_ASSUME_NONNULL_END
