//
//  AFPCHelperProtocol.h
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-15.
//
//  protocol for the AFPHelper xpc service, which handles unmounts and Reveal in Finder unsandboxed for us


#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static NSString *const AFPCHelperServiceName = @"com.benjaminlowry.AFPConnect.AFPHelper";

@protocol AFPCHelperProtocol

/// Unmounts the AFP volume mounted at path (must be the exact mount point). Other paths are refused with EINVAL
- (void)unmountVolumeAtPath:(NSString *)path reply:(void (^)(NSError *_Nullable error))reply;

/// Reveals the AFP volume mounted at url in Finder.
- (void)revealVolumeAtURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
