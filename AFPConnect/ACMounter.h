//
//  ACMounter.h
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-05.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reveals the AFP share mounted at the given URL in a Finder window.
void revealShareInFinder(NSURL *URL);

extern NSString *const ACExtensionBundleID;

@interface ACMountRequest : NSObject
@property (copy) NSString *host;
@property uint16_t port;
/// Nil for guest
@property (copy, nullable) NSString *user;
@property (copy) NSString *volume;
@property (copy, nullable) NSString *password;
/// True to keep the password in the keychain for later mounts.
@property BOOL remember;
@property (copy, nullable) NSString *volumePassword;
@property (copy, nullable) NSString *timefix;
/// Name of AFPEncoding for AFP 2 servers
@property (copy, nullable) NSString *encoding;

/// ``afp://[user@]host[:port]/volume``
- (NSURL *)url;
@end

@interface ACMounter : NSObject

+ (void)mount:(ACMountRequest *)request completion:(void (^)(NSURL *_Nullable mountPoint, NSError *_Nullable error))completion;

+ (BOOL)unmount:(NSURL *)mountPoint error:(NSError **)error;

/// Maps mounted AFP volumes from mount point to source url
+ (NSDictionary<NSURL *, NSString *> *)mountedVolumes;

/// Volumes already mounted on a server, as volume name to mount point. Can block on dns resolution since we deduplicate mounts for the same server under different names
+ (NSDictionary<NSString *, NSURL *> *)mountPointsOnHost:(NSString *)host port:(uint16_t)port;

/// Whether the FSKit extension is installed and enabled. (Nil if it isn't installed at all)
+ (void)checkExtension:(void (^)(BOOL installed, BOOL enabled))completion;

/// Other copies of the app whose AFPFS extension is registered. A mix of notarized and unnotarized copies can cause an ExtensionKit mount failure
+ (void)findDuplicates:(void (^)(NSArray<NSURL *> *duplicates))completion;

/// Whether a mount failed because ExtensionKit couldn't launch AFPFS
+ (BOOL)isExtensionLaunchFailure:(NSError *)error;

@end

NS_ASSUME_NONNULL_END
