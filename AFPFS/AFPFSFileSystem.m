//
//  AFPFSFileSystem.m
//  AFPFS
//
//  Created by Benjamin Lowry on 2026-11-05.
//
//  The main filesystem object that we export to FSKit

#import "AFPFSFileSystem.h"
#import "AFPFSVolume.h"

#import "AFPCLibrary.h"

#import <CommonCrypto/CommonDigest.h>
#import <os/log.h>

static os_log_t fs_log(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.benjaminlowry.AFPConnect.AFPFS", "filesystem");
    });
    return log;
}

/// Calculates a stable UUID based on an SHA-256 of a share's URL, such that a share will be remounted with the same volume ID.
// TODO: come up with the same uuid for the same share even if the url changes?
static NSUUID *uuidForURL(NSURL *url)
{
    NSData *bytes = [url.absoluteString.lowercaseString dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    digest[6] = (digest[6] & 0x0f) | 0x50;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    return [[NSUUID alloc] initWithUUIDBytes:digest];
}

/// Returns the afp:// NSURL corresponding to the given resource, or nil if the given resource isn't an afp:// resource.
static NSURL *_Nullable afpURL(FSResource *resource)
{
    if (![resource isKindOfClass:[FSGenericURLResource class]]) {
        return nil;
    }
    NSURL *url = ((FSGenericURLResource *)resource).url;
    return [url.scheme caseInsensitiveCompare:@"afp"] == NSOrderedSame ? url : nil;
}

@implementation AFPFSFileSystem

- (void)didFinishLoading
{
    [AFPCLibrary start];
}

- (void)probeResource:(FSResource *)resource
         replyHandler:(void (^)(FSProbeResult * _Nullable,
                                NSError * _Nullable))replyHandler {
    NSURL *url = afpURL(resource);
    AFPFSMountTarget *target = url ? [AFPFSMountTarget targetWithURL:url error:NULL] : nil;
    if (!target) {
        replyHandler(FSProbeResult.notRecognizedProbeResult, nil);
        return;
    }
    FSContainerIdentifier *cid = [[FSContainerIdentifier alloc] initWithUUID:uuidForURL(url)];
    replyHandler([FSProbeResult usableProbeResultWithName:target.volumeName containerID:cid], nil);
}


- (void)loadResource:(FSResource *)resource
             options:(FSTaskOptions *)options
        replyHandler:(void (^)(FSVolume * _Nullable, NSError * _Nullable))reply
{
    NSURL *url = afpURL(resource);
    NSError *error = nil;
    AFPFSMountTarget *target = url ? [AFPFSMountTarget targetWithURL:url error:&error] : nil;
    if (!target) {
        os_log_error(fs_log(), "unusable resource %{private}@", url);
        reply(nil, error ?: fs_errorForPOSIXError(EINVAL));
        return;
    }
    [AFPCLibrary start];
    FSVolumeIdentifier *vid = [[FSVolumeIdentifier alloc] initWithUUID:uuidForURL(url)];
    AFPFSVolume *volume = [[AFPFSVolume alloc] initWithVolumeID:vid target:target];
    self.containerStatus = FSContainerStatus.ready;
    reply(volume, nil);
}

- (void)unloadResource:(FSResource *)resource
               options:(FSTaskOptions *)options
          replyHandler:(void (^)(NSError * _Nullable))reply {
    reply(nil);
}

@end
