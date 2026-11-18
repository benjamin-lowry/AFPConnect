//
//  AFPCKeychain.h
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-08.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AFPCKeychain : NSObject

/// Store the password for the given host and username in the app group keychain.
+ (BOOL)savePassword:(NSString *)password forHost:(NSString *)host user:(NSString *)user
               error:(NSError **)error;
/// Return the password for the given host and username saved in the keychain.
+ (nullable NSString *)passwordForHost:(NSString *)host user:(NSString *)user;
/// Delete the password for the given host and username from the keychain.
+ (void)deletePasswordForHost:(NSString *)host user:(NSString *)user;

/// Store a "one-shot" password that shouldn't be remembered; the AFPFS extension reads then deletes the password. Returns the token to pass to the extension.
+ (nullable NSString *)storeOneShotPassword:(NSString *)password error:(NSError **)error;
/// Fetches and returns the one-shot password for the given token, deleting it from the keychain in the process.
+ (nullable NSString *)getAndDeleteOneShotPasswordForToken:(NSString *)token;
/// Deletes the one-shot password for the given token from the keychain.
+ (void)deleteOneShotPasswordForToken:(NSString *)token;
/// Removes all one-shot passwords older than the specified age from the keychain. Use to clean up one-shot passwords that were never used by their mounts.
+ (void)sweepOneShotPasswordsOlderThan:(NSTimeInterval)age;

@end

NS_ASSUME_NONNULL_END
