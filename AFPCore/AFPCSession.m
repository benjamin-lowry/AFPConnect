//
//  AFPCSession.m
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import "AFPCSession.h"
#import "AFPCEncoding.h"
#import "AFPCErrors.h"
#import "AFPCInternal.h"
#import "AFPCLibrary.h"
#import "AFPCServerInfo+Internal.h"
#import "mapping.h"

#import <math.h>
#import <stdatomic.h>

// Same as fuse, minus SHOW_APPLEDOUBLE because extension generates its own AppleDouble files
static const unsigned int kVolumeFlags = VOLUME_EXTRA_FLAGS_NO_LOCKING | VOLUME_EXTRA_FLAGS_IGNORE_UNIXPRIVS;

/// Round the given clock skew to the nearest increment of 15 minutes.
static time_t roundedSkew(time_t skew)
{
    return (time_t)(llround((double)skew / 900.0) * 900);
}

/// Maximum UTC offset that will still qualify for AFPCClockPolicyZone. 14 hours, the furthest real offset from UTC, used for parts of Kiribati including Christmas Island (!)
static const time_t kMaxZoneOffset = 14 * 3600;

@interface AFPCVolumeInfo ()
- (instancetype)initWithName:(NSString *)name hasPassword:(BOOL)hasPassword;
@end

@implementation AFPCVolumeInfo

- (instancetype)initWithName:(NSString *)name hasPassword:(BOOL)hasPassword
{
    self = [super init];
    if (self) {
        _name = [name copy];
        _hasPassword = hasPassword;
    }
    return self;
}

@end

@implementation AFPCSession {
    struct afp_server *_server;
    _Atomic time_t _skew;
    // Server's clock as sent minus ours, from the last measurement
    _Atomic time_t _measured;
    _Atomic AFPCClockPolicy _policy;
    NSMutableArray<NSValue *> *_openVolumes;
    BOOL _closed;
}

+ (instancetype)connectToHost:(NSString *)host port:(uint16_t)port
                         user:(NSString *)user password:(NSString *)password
                 keepPassword:(BOOL)keepPassword error:(NSError **)error
{
    [AFPCLibrary start];

    struct afp_connection_request req;
    memset(&req, 0, sizeof(req));
    afp_default_url(&req.url);
    req.uam_mask = default_uams_mask();
    req.url.port = port;

    if (strlcpy(req.url.servername, host.UTF8String, sizeof(req.url.servername)) >= sizeof(req.url.servername)
            || strlcpy(req.url.username, user.UTF8String ?: "", sizeof(req.url.username)) >= sizeof(req.url.username)
            || strlcpy(req.url.password, password.UTF8String ?: "", sizeof(req.url.password)) >= sizeof(req.url.password)) {
        explicit_bzero(&req, sizeof(req));
        if (error) {
            *error = AFPCError(ENAMETOOLONG, @"The server name, user name or password is too long.");
        }
        return nil;
    }

    // afp_server_full_connect doesn't set errno when the lookup fails.
    // lookup the address ourselves to be sure it resolves, so we can return a more descriptive EHOSTUNREACH errno if it doesn't resolve
    struct addrinfo *address = afp_get_address(NULL, host.UTF8String, port);
    if (!address) {
        explicit_bzero(&req, sizeof(req));
        if (error) {
            *error = AFPCError(EHOSTUNREACH, [NSString stringWithFormat:@"Couldn't find the server \"%@\".", host]);
        }
        return nil;
    }
    freeaddrinfo(address);

    // Pointer so the block doesn't copy the password
    struct afp_connection_request *reqp = &req;
    __block struct afp_server *server = NULL;
    __block int err = 0;
    NSArray<NSString *> *messages = [AFPCLibrary collectMessages:^(void *priv) {
        server = afp_server_full_connect(priv, reqp);
        err = errno;
    }];

    if (!server) {
        explicit_bzero(&req, sizeof(req));
        if (error) {
            *error = AFPCError(err ?: EIO, messages.lastObject);
        }
        return nil;
    }

    // Login clears server->password, put it back in place for reconnect (same as fuse)
    if (keepPassword && req.url.password[0]) {
        strlcpy(server->password, req.url.password, sizeof(server->password));
    }
    explicit_bzero(&req, sizeof(req));

    AFPCSession *session = [[AFPCSession alloc] initWithServer:server];
    return session;
}

- (instancetype)initWithServer:(struct afp_server *)server
{
    self = [super init];
    if (self) {
        _server = server;
        // connect_time is server's clock from FPGetSrvrParms, already adjusted by time_offset for AFP 2
        // _measured is the clock as sent
        _measured = server->connect_time + server->time_offset - time(NULL);
        _skew = [self skewFor:_measured];
        _openVolumes = [NSMutableArray array];
        _serverInfo = [[AFPCServerInfo alloc] initWithServer:server];

        NSMutableArray *volumes = [NSMutableArray array];
        for (int i = 0; i < server->num_volumes; i++) {
            struct afp_volume *v = &server->volumes[i];
            NSString *name = [NSString stringWithUTF8String:v->volume_name_printable];
            if (name) {
                [volumes addObject:[[AFPCVolumeInfo alloc] initWithName:name
                                                            hasPassword:(v->flags & HasPassword) != 0]];
            }
        }
        _volumes = volumes;

        if (server->loginmesg[0]) {
            _loginMessage = [NSString stringWithCString:server->loginmesg encoding:NSUTF8StringEncoding]
                ?: [NSString stringWithCString:server->loginmesg encoding:AFPCEncoding.current];
        }
    }
    return self;
}

- (void)dealloc
{
    [self close];
}

- (struct afp_server *)server
{
    return _server;
}

#pragma mark - Clock handling

- (time_t)clockSkew
{
    return _skew;
}

- (AFPCClockPolicy)clockPolicy
{
    return _policy;
}

- (void)setClockPolicy:(AFPCClockPolicy)policy
{
    _policy = policy;
    _skew = [self skewFor:_measured];
}

// libafpclient turns wall clock into unix time with one fixed offset, which puts Daylight Saving dates an hour off
/// Returns whether the server sends its wall clock (AFP 2 only).
- (BOOL)usesWallClock
{
    return _server->using_version && _server->using_version->av_number < 30;
}

static long gmtoffAt(time_t t)
{
    struct tm tm;
    localtime_r(&t, &tm);
    return tm.tm_gmtoff;
}

/// For AFP 3: seconds to take off server dates.
/// for AFP 2: the server's wall clock minus ours, which is 0 when both are in the same zone and set right.
- (time_t)skewFor:(time_t)measured
{
    time_t now = time(NULL);
    if (_policy == AFPCClockPolicyLocal) {
        // Local time AFP 3 servers send UTC plus their offset, so use ours.
        // AFP 2 wall clocks are already read as local times here
        return [self usesWallClock] ? 0 : gmtoffAt(now);
    }
    time_t raw = [self usesWallClock] ? measured - gmtoffAt(now) : measured;
    time_t wanted = roundedSkew(raw);
    if (_policy == AFPCClockPolicyZone && llabs((long long)wanted) > kMaxZoneOffset) {
        wanted = 0;
    }
    return wanted;
}

- (struct timespec)localTimeFromServer:(struct timespec)t
{
    if (![self usesWallClock]) {
        t.tv_sec -= _skew;
        return t;
    }
    // go back to the server's wall clock, then read it as a local time here
    time_t wall = t.tv_sec + _server->time_offset - _skew;
    struct tm tm;
    gmtime_r(&wall, &tm);
    tm.tm_isdst = -1;
    t.tv_sec = mktime(&tm);
    return t;
}

- (time_t)serverTimeFromLocal:(time_t)t
{
    if (![self usesWallClock]) {
        return t + _skew;
    }
    time_t wall = t + gmtoffAt(t) + _skew;
    // libafpclient adds time_offset back when it encodes the date.
    return wall - _server->time_offset;
}

- (BOOL)refreshClockSkew
{
    if (_policy == AFPCClockPolicyLocal) {
        // nothing to ask the server, but this Mac's offset can change
        time_t skew = [self skewFor:_measured];
        return atomic_exchange(&_skew, skew) != skew;
    }
    time_t serverTime;
    @synchronized (self) {
        if (_closed || afp_getsrvrtime(_server, &serverTime) != 0) {
            return NO;
        }
    }
    _measured = serverTime - time(NULL);
    time_t skew = [self skewFor:_measured];
    return atomic_exchange(&_skew, skew) != skew;
}

#pragma mark - Volume open/close

- (struct afp_volume *)openVolumeNamed:(NSString *)name password:(NSString *)password error:(NSError **)error
{
    @synchronized (self) {
        return [self lockedOpenVolumeNamed:name password:password error:error];
    }
}

- (struct afp_volume *)lockedOpenVolumeNamed:(NSString *)name password:(NSString *)password error:(NSError **)error
{
    char volname[AFP_VOLUME_NAME_UTF8_LEN];
    if (_closed || strlcpy(volname, name.UTF8String, sizeof(volname)) >= sizeof(volname)) {
        if (error) {
            *error = AFPCError(_closed ? ENOTCONN : ENAMETOOLONG, nil);
        }
        return NULL;
    }

    struct afp_volume *volume = find_volume_by_name(_server, volname);
    if (!volume) {
        if (error) {
            *error = AFPCError(ENOENT, [NSString stringWithFormat:@"The server has no volume named \"%@\".", name]);
        }
        return NULL;
    }

    memset(volume->volpassword, 0, AFP_VOLPASS_LEN);
    if (volume->flags & HasPassword) {
        // volume passwords are at most 8 bytes over the network
        const char *pw = password.UTF8String ?: "";
        if (!pw[0] || strlen(pw) >= AFP_VOLPASS_LEN) {
            if (error) {
                *error = AFPCError(EAUTH, @"This volume needs a password of at most 8 characters.");
            }
            return NULL;
        }
        strlcpy(volume->volpassword, pw, AFP_VOLPASS_LEN);
    }

    char mesg[MAX_ERROR_LEN] = { 0 };
    unsigned int len = 0;
    if (afp_connect_volume(volume, _server, mesg, &len, sizeof(mesg))) {
        // only returns 1, the reason is in the message text
        int code = EIO;
        if (strstr(mesg, "password")) {
            code = EAUTH;
        } else if (strstr(mesg, "Timed out")) {
            code = ETIMEDOUT;
        }
        NSString *message = [[NSString stringWithUTF8String:mesg]
                                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (error) {
            *error = AFPCError(code, message.length ? message
                                     : [NSString stringWithFormat:@"Couldn't open the volume \"%@\".", name]);
        }
        return NULL;
    }

    volume->server = _server;
    volume->extra_flags |= kVolumeFlags;
    volume->mapping = AFP_MAPPING_UNKNOWN;
    afp_detect_mapping(volume);
    volume->mount_time = time(NULL);
    [_openVolumes addObject:[NSValue valueWithPointer:volume]];
    return volume;
}

- (void)close
{
    @synchronized (self) {
        [self lockedClose];
    }
}

- (void)lockedClose
{
    if (_closed || !_server) {
        return;
    }
    _closed = YES;
    explicit_bzero(_server->password, sizeof(_server->password));
    BOOL connected = _server->connect_state == SERVER_STATE_CONNECTED;

    /* End the session the way the Mac OS X client would:
       close the volumes,
       log out,
       close session.
     
       libafpclient's detach sends logout without waiting for it and then drops
       the connection; this can cause problems on at least AppleShare IP 5.0
       where sessions that aren't properly closed never time out and will eat up
       the server's concurrent connection limit
     */
    @synchronized ([AFPCSession class]) {
        afp_set_auto_disconnect_on_unmount(0);
        for (NSValue *v in _openVolumes) {
            struct afp_volume *volume = v.pointerValue;
            if (connected) {
                afp_volclose(volume);
            }
            afp_unmount_volume(volume);
        }
        [_openVolumes removeAllObjects];
        afp_set_auto_disconnect_on_unmount(1);
    }
    if (connected) {
        afp_logout(_server, DSI_DEFAULT_TIMEOUT);
        struct dsi_header header;
        afpc_dsi_setup_header(_server, &header, DSI_DSICloseSession);
        afpc_dsi_send(_server, (char *)&header, sizeof(header), DSI_DONT_WAIT, 0, NULL);
    }
    afp_server_remove(_server);
    _server = NULL;
}

@end
