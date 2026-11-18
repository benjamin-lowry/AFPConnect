//
//  AFPCSession.h
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import <Foundation/Foundation.h>

#import "AFPCServerInfo.h"

NS_ASSUME_NONNULL_BEGIN

struct afp_server;
struct afp_volume;

@interface AFPCVolumeInfo : NSObject
@property (readonly, copy) NSString *name;
@property (readonly) BOOL hasPassword;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Represents one logged-in AFP session (connect, list volumes, open volumes, log out)
@interface AFPCSession : NSObject

/// Return a new AFPCSession connected to the given host. Blocking. A nil or empty user causes a guest login. If keepPassword is YES, the password is held so libafpclient can use it to reconnect after a connection is dropped.
+ (nullable instancetype)connectToHost:(NSString *)host
                                  port:(uint16_t)port
                                  user:(nullable NSString *)user
                              password:(nullable NSString *)password
                          keepPassword:(BOOL)keepPassword
                                 error:(NSError **)error;

@property (readonly) AFPCServerInfo *serverInfo;
@property (readonly, copy) NSArray<AFPCVolumeInfo *> *volumes;
/// The server's login greeting, if it sent one.
@property (readonly, copy, nullable) NSString *loginMessage;
@property (readonly) struct afp_server *server;
/// How server dates are corrected (AFP can't tell a server's time zone from a clock error, all we have is the server's timestamp minus ours)
typedef NS_ENUM(NSInteger, AFPCClockPolicy) {
    /// Map the server's now to ours, whatever the difference. (libafpclient's standard behavior for AFP 2).
    AFPCClockPolicyAll,
    /// Only correct differences within the maximum time zone offset from UTC (up to 14 hours), so a server with a badly set clock keeps its files' real dates.
    AFPCClockPolicyZone,
    /// Never ask for the server's clock. Instead, read all dates as if they were in this Mac's time zone.
    AFPCClockPolicyLocal,
};

/// The clock policy in use for this session.
@property (atomic) AFPCClockPolicy clockPolicy;

/// The server's clock offset being corrected, in seconds (for logging).
// Apple's AFP server sends local time even over AFP 3 (tested on10.4, 10.6, and 10.7)
@property (readonly, atomic) time_t clockSkew;

// afp 2 dates are server's wall clock, so we read them as local times with local daylight saving rules
// afp 3 dates just lose the measured skew
/// Converts the given timespec from server time to this Mac's local time according to the clock policy in use for this session.
- (struct timespec)localTimeFromServer:(struct timespec)t;

/// Convert the given time\_t from this Mac's local time to server time
- (time_t)serverTimeFromLocal:(time_t)t;

/// Refreshes the server clock and updates the clock skew if necessary. Returns YES/NO whether the skew changed. Blocking.
- (BOOL)refreshClockSkew;

// blocking. volumes are matched by name the way libafpclient does it
// (precomposed, case sensitive)
/// Opens a volume with the provided name (and volume password if applicable). Volumes are matched by name identically to libafpclient (precomposed/case sensitive). Blocking.
- (nullable struct afp_volume *)openVolumeNamed:(NSString *)name
                                       password:(nullable NSString *)password
                                          error:(NSError **)error;

/// Unmounts any open volumes and logs out, session is unusable after
- (void)close;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
