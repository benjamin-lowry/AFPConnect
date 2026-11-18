//
//  ACMounter.m
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-05.
//

#import "ACMounter.h"

#import "AFPCKeychain.h"
#import "AFPCHelperProtocol.h"

#import <FSKit/FSKit.h>
#import <os/log.h>
#import <netdb.h>
#import <sys/mount.h>

NSString *const ACExtensionBundleID = @"com.benjaminlowry.AFPConnect.AFPFS";

static os_log_t mount_log(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.benjaminlowry.AFPConnect", "mount");
    });
    return log;
}

/// Reveal the AFPFS share mounted at URL in the Finder (via the AFPHelper XPC service).
void revealShareInFinder(NSURL *URL)
{
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithServiceName:AFPCHelperServiceName];
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(AFPCHelperProtocol)];
    [connection resume];
    [[connection remoteObjectProxy] revealVolumeAtURL:URL];
    [connection invalidate];
}

@implementation ACMountRequest

- (NSURL *)url
{
    NSURLComponents *c = [[NSURLComponents alloc] init];
    c.scheme = @"afp";
    c.host = self.host;
    if (self.port && self.port != 548) {
        c.port = @(self.port);
    }
    if (self.user.length) {
        c.user = self.user;
    }
    c.path = [@"/" stringByAppendingString:self.volume];
    return c.URL;
}

@end

@implementation ACMounter

+ (void)mount:(ACMountRequest *)request completion:(void (^)(NSURL *, NSError *))completion
{
    void (^finish)(NSURL *, NSError *) = ^(NSURL *point, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(point, error);
        });
    };

    // the password goes through the keychain, not the url or a visible option
    NSMutableArray<NSString *> *options = [NSMutableArray array];
    NSString *token = nil;
    if (request.user.length && request.password) {
        NSError *error = nil;
        if (request.remember) {
            if (![AFPCKeychain savePassword:request.password forHost:request.host user:request.user error:&error]) {
                finish(nil, error);
                return;
            }
        } else if (!(token = [AFPCKeychain storeOneShotPassword:request.password error:&error])) {
            finish(nil, error);
            return;
        }
    }
    NSString *volumeToken = nil;
    if (request.volumePassword.length) {
        NSError *error = nil;
        if (!(volumeToken = [AFPCKeychain storeOneShotPassword:request.volumePassword error:&error])) {
            if (token) {
                [AFPCKeychain deleteOneShotPasswordForToken:token];
            }
            finish(nil, error);
            return;
        }
    }
    if (token) {
        [options addObject:[@"token=" stringByAppendingString:token]];
    }
    if (volumeToken) {
        [options addObject:[@"voltoken=" stringByAppendingString:volumeToken]];
    }
    if (request.timefix.length && ![request.timefix isEqualToString:@"all"]) {
        [options addObject:[@"timefix=" stringByAppendingString:request.timefix]];
    }
    if (request.encoding.length && ![request.encoding isEqualToString:@"macroman"]) {
        [options addObject:[@"encoding=" stringByAppendingString:request.encoding]];
    }
    NSArray<NSString *> *args = options.count ? @[ @"-o", [options componentsJoinedByString:@","] ] : @[];
    NSURL *url = request.url;

    void (^done)(NSURL *, NSError *) = ^(NSURL *point, NSError *error) {
        // Extension deletes the token when it reads it, this block cleans it up for mounts that don't reach the extension
        if (token) {
            [AFPCKeychain deleteOneShotPasswordForToken:token];
        }
        if (volumeToken) {
            [AFPCKeychain deleteOneShotPasswordForToken:volumeToken];
        }
        finish(point, error);
    };

    FSGenericURLResource *resource = [[FSGenericURLResource alloc] initWithURL:url];
    [FSClient.sharedInstance mountSingleVolumeForResource:resource bundleID:ACExtensionBundleID options:args
                                        completionHandler:^(NSURL *point, NSError *error) {
        if (point) {
            os_log(mount_log(), "mounted %{private}@ at %{public}@", url, point.path);
            done(point, nil);
            return;
        }
        os_log(mount_log(), "fskit mount failed (%{public}@)", error);
        done(nil, [self explainBusy:error url:url]);
    }];
}

+ (BOOL)isExtensionLaunchFailure:(NSError *)error
{
    // _EXErrorCode 2 is the launch failure from ExtensionFoundation's AppExtensionProcess.launch
    return [error.domain isEqualToString:@"com.apple.extensionKit.errorDomain"] && error.code == 2;
}

/// Creates the error message for a device busy error on the mount point
+ (NSError *)explainBusy:(NSError *)error url:(NSURL *)url
{
    if (![error.domain isEqualToString:NSPOSIXErrorDomain] || error.code != EBUSY) {
        return error;
    }
    NSDictionary<NSURL *, NSString *> *mounted = [self mountedVolumes];
    NSURL *point = [mounted allKeysForObject:url.absoluteString].firstObject;
    NSString *reason = point
        ? [NSString stringWithFormat:@"The share is already mounted at %@.", point.path]
        : @"The share cannot be mounted due to an earlier mount failure. Restart your Mac, then try again.";
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:EBUSY userInfo:@{
        NSLocalizedDescriptionKey: error.localizedDescription,
        NSLocalizedFailureReasonErrorKey: reason,
        NSUnderlyingErrorKey: error,
    }];
}

/// We can't unmount from the sandbox, so this blocking method tells AFPHelper to do it over xpc
+ (BOOL)unmount:(NSURL *)mountPoint error:(NSError **)error
{
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithServiceName:AFPCHelperServiceName];
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(AFPCHelperProtocol)];
    [connection resume];
    __block NSError *result = nil;
    id<AFPCHelperProtocol> helper = [connection synchronousRemoteObjectProxyWithErrorHandler:^(NSError *e) {
        os_log_error(mount_log(), "AFPHelper: %{public}@", e);
        result = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{ NSUnderlyingErrorKey: e }];
    }];
    [helper unmountVolumeAtPath:mountPoint.path reply:^(NSError *e) {
        if (e) {
            result = e;
        }
    }];
    [connection invalidate];
    if (result && error) {
        *error = result;
    }
    return result == nil;
}

+ (NSDictionary<NSURL *, NSString *> *)mountedVolumes
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    struct statfs *mounts = NULL;
    int count = getmntinfo_r_np(&mounts, MNT_NOWAIT);
    for (int i = 0; i < count; i++) {
        if (strcmp(mounts[i].f_fstypename, "afp") == 0) {
            NSURL *point = [NSURL fileURLWithFileSystemRepresentation:mounts[i].f_mntonname isDirectory:YES relativeToURL:nil];
            result[point.URLByStandardizingPath] = @(mounts[i].f_mntfromname);
        }
    }
    free(mounts);
    return result;
}

static NSString *normalHost(NSString *host)
{
    host = host.lowercaseString;
    return [host hasSuffix:@"."] ? [host substringToIndex:host.length - 1] : host;
}

/// Returns the addresses a host resolves to, as a set of raw in\_addr/in6\_addr bytes
static NSSet<NSData *> *addressesOf(NSString *host)
{
    NSMutableSet *result = [NSMutableSet set];
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM }, *list = NULL;
    if (getaddrinfo(host.UTF8String, NULL, &hints, &list) != 0) {
        return result;
    }
    for (struct addrinfo *ai = list; ai; ai = ai->ai_next) {
        if (ai->ai_family == AF_INET) {
            struct sockaddr_in *sin = (struct sockaddr_in *)ai->ai_addr;
            [result addObject:[NSData dataWithBytes:&sin->sin_addr length:sizeof(sin->sin_addr)]];
        } else if (ai->ai_family == AF_INET6) {
            struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)ai->ai_addr;
            [result addObject:[NSData dataWithBytes:&sin6->sin6_addr length:sizeof(sin6->sin6_addr)]];
        }
    }
    freeaddrinfo(list);
    return result;
}

+ (NSDictionary<NSString *, NSURL *> *)mountPointsOnHost:(NSString *)host port:(uint16_t)port
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSDictionary<NSURL *, NSString *> *mounted = [self mountedVolumes];
    NSSet<NSData *> *addresses = nil;
    NSMutableDictionary<NSString *, NSSet<NSData *> *> *lookups = [NSMutableDictionary dictionary];
    for (NSURL *point in mounted) {
        // Source is URL the volume was mounted with
        NSURLComponents *c = [NSURLComponents componentsWithString:mounted[point]];
        uint16_t p = c.port ? c.port.unsignedShortValue : 548;
        NSString *name = [c.path hasPrefix:@"/"] ? [c.path substringFromIndex:1] : c.path;
        if (!c.host || !name.length || p != (port ?: 548) || result[name]) {
            continue;
        }
        BOOL same = [normalHost(c.host) isEqualToString:normalHost(host)];
        if (!same) {
            addresses = addresses ?: addressesOf(host);
            NSString *key = normalHost(c.host);
            if (!lookups[key]) {
                lookups[key] = addressesOf(c.host);
            }
            same = [lookups[key] intersectsSet:addresses];
        }
        if (same) {
            result[name] = point;
        }
    }
    return result;
}

/// Returns the app bundle containing an extension, or the extension itself if it isn't in one
static NSURL *containingApp(NSURL *extension)
{
    for (NSURL *u = extension; u.path.length > 1; u = u.URLByDeletingLastPathComponent) {
        if ([u.pathExtension isEqualToString:@"app"]) {
            return u;
        }
    }
    return extension;
}

+ (void)checkExtension:(void (^)(BOOL, BOOL))completion
{
    [FSClient.sharedInstance fetchInstalledExtensionsWithCompletionHandler:^(NSArray<FSModuleIdentity *> *modules, NSError *error) {
        BOOL installed = NO, enabled = NO;
        for (FSModuleIdentity *m in modules) {
            if ([m.bundleIdentifier isEqualToString:ACExtensionBundleID]) {
                installed = YES;
                enabled = m.isEnabled;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(installed, enabled);
        });
    }];
}

+ (void)findDuplicates:(void (^)(NSArray<NSURL *> *))completion
{
    NSString *ours = [NSBundle.mainBundle.bundleURL.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
    [FSClient.sharedInstance fetchInstalledExtensionsWithCompletionHandler:^(NSArray<FSModuleIdentity *> *modules, NSError *error) {
        NSMutableArray<NSURL *> *duplicates = [NSMutableArray array];
        for (FSModuleIdentity *m in modules) {
            if (![m.bundleIdentifier isEqualToString:ACExtensionBundleID] || [m.url.URLByResolvingSymlinksInPath.path hasPrefix:ours]) {
                continue;
            }
            NSURL *app = containingApp(m.url);
            if (![duplicates containsObject:app]) {
                [duplicates addObject:app];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(duplicates);
        });
    }];
}

@end
