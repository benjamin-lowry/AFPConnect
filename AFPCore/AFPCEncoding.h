//
//  AFPCEncoding.h
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AFPCEncoding : NSObject

/// Short names for mount option, in the order they appear in the menu
@property (class, readonly, copy) NSArray<NSString *> *names;

/// Returns the display name for the given AFP encoding (CFStringGetNameOfEncoding)
+ (NSString *)displayNameFor:(NSString *)name;

// what Classic Mac OS in this Mac's language would use, otherwise macroman
@property (class, readonly, copy) NSString *defaultName;

/// Sets encoding for all AFP 2 connections of the process. Call before connecting to a server. Returns YES if the encoding was set properly, NO if the given encoding is unknown (which leaves the encoding unchanged).
+ (BOOL)useEncodingNamed:(NSString *)name;

/// The current encoding in use for strings that AFPCore decodes itself (server name, login msg, desktop db comments)
@property (class, readonly) NSStringEncoding current;
@property (class, readonly, copy) NSString *currentName;

@end

NS_ASSUME_NONNULL_END
