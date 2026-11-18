//
//  AFPCServerInfo.h
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//
//  gives all the stuff FPGetSrvrInfo tells us about a server without logging into it

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AFPCServerType) {
    AFPCServerTypeUnknown,
    AFPCServerTypeNetatalk,
    AFPCServerTypeAirPort,
    AFPCServerTypeMacintosh,
    AFPCServerTypeTimeCapsule,
    AFPCServerTypeWindows,
};

@interface AFPCServerInfo : NSObject

@property (readonly, copy) NSString *name;
@property (readonly, copy) NSString *machineType;
@property (readonly) AFPCServerType serverType;
/// AFP versions as protocol numbers (e.g. 2.2 -> 22, 3.4 -> 34), oldest first
@property (readonly, copy) NSArray<NSNumber *> *versions;
@property (readonly, copy) NSArray<NSString *> *uamNames;
@property (readonly) BOOL supportsGuest;
/// 256 bytes: 32x32 1-bit icon followed by mask, or nil if the server didn't give us one
@property (readonly, copy, nullable) NSData *icon;

/// Blocking. Don't call on main thread
+ (nullable instancetype)probeHost:(NSString *)host
                              port:(uint16_t)port
                             error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
