//
//  main.m
//  AFPHelper
//
//  Created by Benjamin Lowry on 2026-11-15.
//
// unsandboxed XPC service that only AFPConnect can talk to
// its purpose is to handle tasks FSKit doesn't let us punch through the sandbox to do
// (unmount volumes we mounted and reveal them in Finder)
//

#import <Foundation/Foundation.h>
#import <DiskArbitration/DiskArbitration.h>
#import <mach/error.h>
#import <os/log.h>
#import <sys/mount.h>
#include <AppKit/NSWorkspace.h>

#import "AFPCHelperProtocol.h"

#define AFP_FSNAME "afp"
#define AFP_URLPREFIX "afp://"

static os_log_t helper_log(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.benjaminlowry.AFPConnect.AFPHelper", "helper");
    });
    return log;
}

/// returns YES/NO whether the given path is the mount point of an AFPConnect volume
static BOOL isAFPMount(NSString *path)
{
    BOOL found = NO;
    
    // trim trailing slash
    while (path.length > 1 && [path hasSuffix:@"/"]) {
        path = [path substringToIndex:path.length - 1];
    }
    if (!path.length)
        goto logandreturn;
        
    const char *want = path.fileSystemRepresentation;
    struct statfs *mounts = NULL;
    int count = getmntinfo_r_np(&mounts, MNT_NOWAIT);
    for (int i = 0; i < count; i++) {
        if (strcmp(mounts[i].f_mntonname, want) == 0) {
            found = memcmp(mounts[i].f_fstypename, AFP_FSNAME, sizeof(AFP_FSNAME) - 1) == 0 && (mounts[i].f_flags_ext & MNT_EXT_FSKIT)
                    && memcmp(mounts[i].f_mntfromname, AFP_URLPREFIX, sizeof(AFP_URLPREFIX) - 1) == 0;
            break;
        }
    }
    free(mounts);
logandreturn:
    if (!found)
        os_log_error(helper_log(), "refusing %{public}@ (not an AFP volume mount point)", path);
    return found;
}

struct UnmountContext {
    dispatch_semaphore_t done;
    int error;
};

static void unmounted(DADiskRef disk, DADissenterRef dissenter, void *context)
{
    struct UnmountContext *c = context;
    if (dissenter) {
        DAReturn status = DADissenterGetStatus(dissenter);
        CFStringRef why = DADissenterGetStatusString(dissenter);
        os_log_error(helper_log(), "diskarbitration dissented: 0x%x %{public}@", status, why ?: CFSTR(""));
        if ((status & ~0x3fff) == unix_err(0)) {
            c->error = status & 0x3fff;
        } else {
            c->error = status == kDAReturnBusy ? EBUSY : status == kDAReturnNotPermitted ? EPERM : EIO;
        }
    }
    dispatch_semaphore_signal(c->done);
}

/// Unmounts the AFP volume mounted at mountPoint via the DiskArbitration API.
// we can't use unmount(2) since the mount is owned by root
static int unmountWithDiskArbitration(NSURL *mountPoint)
{
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    if (!session) {
        return EIO;
    }
    DADiskRef disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, (__bridge CFURLRef)mountPoint);
    if (!disk) {
        CFRelease(session);
        return ENOENT;
    }
    dispatch_queue_t queue = dispatch_queue_create("com.benjaminlowry.AFPConnect.AFPHelper.da", DISPATCH_QUEUE_SERIAL);
    DASessionSetDispatchQueue(session, queue);
    struct UnmountContext c = { dispatch_semaphore_create(0), 0 };
    DADiskUnmount(disk, kDADiskUnmountOptionDefault, unmounted, &c);
    BOOL timedOut = dispatch_semaphore_wait(c.done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) != 0;
    DASessionSetDispatchQueue(session, NULL);
    dispatch_sync(queue, ^{});
    if (timedOut) {
        c.error = ETIMEDOUT;
    }
    CFRelease(disk);
    CFRelease(session);
    return c.error;
}

@interface AFPHelper : NSObject <AFPCHelperProtocol, NSXPCListenerDelegate>
@end

@implementation AFPHelper

/// Unmounts the AFP volume mounted at path, then calls reply, passing the unmount status as an NSError.
- (void)unmountVolumeAtPath:(NSString *)path reply:(void (^)(NSError *))reply
{
    int err = 0;
    if (isAFPMount(path)) {
        err = unmount(path.fileSystemRepresentation, 0) == 0 ? 0 : errno;
        os_log_debug(helper_log(), "unmount(2) %{public}@: %d", path, err);
        if (err == EPERM) {
            err = unmountWithDiskArbitration([NSURL fileURLWithPath:path isDirectory:YES]);
        }
        os_log(helper_log(), "unmount %{public}@: %d", path, err);
    } else {
        err = EINVAL;
    }
    reply(err ? [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil] : nil);
}

/// Reveals the AFP volume mounted at url in the Finder.
- (void)revealVolumeAtURL:(NSURL *)url
{
    if (url.isFileURL && isAFPMount(url.path))
        [[NSWorkspace sharedWorkspace] openURL:url];
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection
{
    // deny connections not from the AFPConnect app signed by whoever built this target
    connection.codeSigningRequirement = @"anchor apple generic and identifier \"com.benjaminlowry.AFPConnect\" "
                                        @"and certificate leaf[subject.OU] = \"" AFP_TEAM_ID "\"";
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(AFPCHelperProtocol)];
    connection.exportedObject = self;
    [connection resume];
    return YES;
}

@end

int main(int argc, const char *argv[])
{
    static AFPHelper *service;
    service = [[AFPHelper alloc] init];
    NSXPCListener *listener = [NSXPCListener serviceListener];
    listener.delegate = service;
    [listener resume];
    return 0;
}
