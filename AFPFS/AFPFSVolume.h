//
//  AFPFSVolume.h
//  AFPFS
//
//  Created by Benjamin Lowry on 2026-11-06.
//

#import <FSKit/FSKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AFPFSMountTarget : NSObject
@property (copy) NSString *host;
@property uint16_t port;
@property (copy, nullable) NSString *user;
@property (copy) NSString *volumeName;

/// Create an AFPFSVolume from an AFP connect url, i.e. ``afp://[user[;AUTH=uam]@]host[:port]/volume``.
/// Passwords cannot be included in the URL and URLs containing passwords will be refused, since FSKit includes the password verbatim in df output (which would expose the password to other local users!)
+ (nullable instancetype)targetWithURL:(NSURL *)url error:(NSError **)error;
@end

// Conforms to XattrHandler so we can tell FSKit not to use xattrs (triggering the xnu AppleDouble fallback)
@interface AFPFSVolume : FSVolume <FSVolumeHandler, FSVolumeOpenCloseHandler, FSVolumeReadWriteHandler, FSVolumeXattrHandler, FSVolumeDataCacheHandler>

- (instancetype)initWithVolumeID:(FSVolumeIdentifier *)volumeID
                          target:(AFPFSMountTarget *)target;

@end

NS_ASSUME_NONNULL_END
