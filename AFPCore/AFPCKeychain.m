//
//  AFPCKeychain.m
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-08.
//

#import "AFPCKeychain.h"

#import <Security/Security.h>

static NSString *const kAccessGroup = @AFP_TEAM_ID ".com.benjaminlowry.AFPConnect";
static NSString *const kOneShotService = @"com.benjaminlowry.AFPConnect.mount-token";

static NSMutableDictionary *baseQuery(CFTypeRef cls)
{
    return [@{
        (__bridge id)kSecClass: (__bridge id)cls,
        (__bridge id)kSecAttrAccessGroup: kAccessGroup,
        (__bridge id)kSecUseDataProtectionKeychain: @YES,
        (__bridge id)kSecAttrSynchronizable: @NO,
    } mutableCopy];
}

static NSMutableDictionary *loginQuery(NSString *host, NSString *user)
{
    NSMutableDictionary *q = baseQuery(kSecClassInternetPassword);
    q[(__bridge id)kSecAttrServer] = host.lowercaseString;
    q[(__bridge id)kSecAttrAccount] = user;
    q[(__bridge id)kSecAttrProtocol] = (__bridge id)kSecAttrProtocolAFP;
    return q;
}

static NSMutableDictionary *tokenQuery(NSString *token)
{
    NSMutableDictionary *q = baseQuery(kSecClassGenericPassword);
    q[(__bridge id)kSecAttrService] = kOneShotService;
    if (token) {
        q[(__bridge id)kSecAttrAccount] = token;
    }
    return q;
}

static NSError *keychainError(OSStatus status)
{
    NSString *message = CFBridgingRelease(SecCopyErrorMessageString(status, NULL));
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                           userInfo:message ? @{ NSLocalizedFailureReasonErrorKey: message } : nil];
}

static NSString *copyPassword(NSMutableDictionary *query)
{
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef data = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &data) != errSecSuccess || !data) {
        return nil;
    }
    NSString *password = [[NSString alloc] initWithData:(__bridge_transfer NSData *)data
                                               encoding:NSUTF8StringEncoding];
    return password;
}

@implementation AFPCKeychain

+ (BOOL)savePassword:(NSString *)password forHost:(NSString *)host user:(NSString *)user error:(NSError **)error
{
    NSMutableDictionary *query = loginQuery(host, user);
    SecItemDelete((__bridge CFDictionaryRef)query);
    query[(__bridge id)kSecValueData] = [password dataUsingEncoding:NSUTF8StringEncoding];
    // after first unlock so scripted/background mounts work with the screen locked
    query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    query[(__bridge id)kSecAttrLabel] = host;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    if (status != errSecSuccess && error) {
        *error = keychainError(status);
    }
    return status == errSecSuccess;
}

+ (NSString *)passwordForHost:(NSString *)host user:(NSString *)user
{
    return copyPassword(loginQuery(host, user));
}

+ (void)deletePasswordForHost:(NSString *)host user:(NSString *)user
{
    SecItemDelete((__bridge CFDictionaryRef)loginQuery(host, user));
}

+ (NSString *)storeOneShotPassword:(NSString *)password error:(NSError **)error
{
    NSString *token = NSUUID.UUID.UUIDString;
    NSMutableDictionary *query = tokenQuery(token);
    query[(__bridge id)kSecValueData] = [password dataUsingEncoding:NSUTF8StringEncoding];
    query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    if (status != errSecSuccess) {
        if (error) {
            *error = keychainError(status);
        }
        return nil;
    }
    return token;
}

+ (NSString *)getAndDeleteOneShotPasswordForToken:(NSString *)token
{
    NSString *password = copyPassword(tokenQuery(token));
    [self deleteOneShotPasswordForToken:token];
    return password;
}

+ (void)deleteOneShotPasswordForToken:(NSString *)token
{
    SecItemDelete((__bridge CFDictionaryRef)tokenQuery(token));
}

+ (void)sweepOneShotPasswordsOlderThan:(NSTimeInterval)age
{
    NSMutableDictionary *query = tokenQuery(nil);
    query[(__bridge id)kSecReturnAttributes] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) {
        return;
    }
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-age];
    for (NSDictionary *item in (__bridge_transfer NSArray *)result) {
        NSDate *created = item[(__bridge id)kSecAttrCreationDate];
        NSString *token = item[(__bridge id)kSecAttrAccount];
        if (token && (!created || [created compare:cutoff] == NSOrderedAscending)) {
            [self deleteOneShotPasswordForToken:token];
        }
    }
}

@end
