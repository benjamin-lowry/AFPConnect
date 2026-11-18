//
//  ACBrowser.h
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-14.
//
//  Finds AFP servers on the local network via Network.framework's bonjour browser,
//  as a replacement for the equivalent functionality in the Finder Network tab
#import <Foundation/Foundation.h>
#import <Network/Network.h>

NS_ASSUME_NONNULL_BEGIN

@interface ACService : NSObject
@property (readonly, copy) NSString *name;
@property (readonly) nw_endpoint_t endpoint;
// host and port from srv record, these are what we actually use to connect
@property (readonly, copy) NSString *host;
@property (readonly) uint16_t port;
@end

@interface ACBrowser : NSObject

/// Called from main queue when the list list of services changes. On error, an empty list is passed. Services aren't listed until they have been resolved.
@property (copy, nullable) void (^changeHandler)(NSArray<ACService *> *services, NSError *_Nullable error);
@property (readonly, copy) NSArray<ACService *> *services;

/// Start browsing for AFP servers advertised over Bonjour.
- (void)start;
/// Stop browsing for AFP servers advertised over Bonjour.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
