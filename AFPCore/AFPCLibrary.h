//
//  AFPCLibrary.h
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One-time libafpclient setup shared by the app and the extension
@interface AFPCLibrary : NSObject

/// Registers callbacks, loads the uams and starts the event loop thread. Safe to call any number of times from any thread since only the first call does anything
+ (void)start;

/// Runs block with a token to pass as libafpclient's priv argument, returns the error messages the library logged for that token oldest first
+ (NSArray<NSString *> *)collectMessages:(void (NS_NOESCAPE ^)(void *priv))block;

@end

NS_ASSUME_NONNULL_END
