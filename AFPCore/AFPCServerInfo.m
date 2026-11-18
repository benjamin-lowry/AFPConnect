//
//  AFPCServerInfo.m
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import "AFPCServerInfo+Internal.h"
#import "AFPCEncoding.h"
#import "AFPCErrors.h"
#import "AFPCInternal.h"
#import "AFPCLibrary.h"
#import "uam_registry.h"

// afp_strings in uams.c
// lowest bit first
static NSArray<NSString *> *uamNames(unsigned int mask)
{
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int bit = 0; bit < 32; bit++) {
        if (mask & (1u << bit)) {
            char *name = uam_bitmap_to_string(1u << bit);
            if (name) {
                [names addObject:@(name)];
            }
        }
    }
    return names;
}

@implementation AFPCServerInfo

- (instancetype)initWithServer:(const struct afp_server *)server
{
    self = [super init];
    if (self) {
        struct afpc_server_info basic;
        afp_server_fill_basic(server, &basic);

        // Decode raw MacRoman name here
        NSString *name = nil;
        if (server->flags & kSupportsUTF8SrvrName) {
            name = [NSString stringWithUTF8String:basic.server_name_printable];
        }
        if (!name.length) {
            name = [NSString stringWithCString:server->server_name encoding:AFPCEncoding.current];
        }
        _name = [name copy] ?: @"";

        _machineType = [NSString stringWithCString:basic.machine_type encoding:NSMacOSRomanStringEncoding] ?: @"";
        _serverType = (AFPCServerType)basic.server_type;

        NSMutableArray *versions = [NSMutableArray array];
        for (int i = 0; i < AFPC_MAX_VERSIONS && basic.versions[i]; i++) {
            [versions addObject:@(basic.versions[i])];
        }
        _versions = [versions sortedArrayUsingSelector:@selector(compare:)];

        _uamNames = uamNames(basic.supported_uams);
        _supportsGuest = (basic.supported_uams & UAM_NOUSERAUTHENT) != 0;

        BOOL hasIcon = NO;
        for (int i = 0; i < AFPC_SERVER_ICON_LEN; i++) {
            if (basic.icon[i]) {
                hasIcon = YES;
                break;
            }
        }
        _icon = hasIcon ? [NSData dataWithBytes:basic.icon length:AFPC_SERVER_ICON_LEN] : nil;
    }
    return self;
}

+ (instancetype)probeHost:(NSString *)host port:(uint16_t)port error:(NSError **)error
{
    [AFPCLibrary start];

    struct addrinfo *address = afp_get_address(NULL, host.UTF8String, port);
    if (!address) {
        if (error) {
            *error = AFPCError(EHOSTUNREACH, [NSString stringWithFormat:@"Couldn't find the server \"%@\".", host]);
        }
        return nil;
    }

    // nothing in libafpclient frees the address list, and the server may
    // outlive afp_server_remove while the loop retains it, so it leaks like
    // in afp_server_full_connect (one small addrinfo per probe)
    struct afp_server *server = afp_server_init(address);
    if (!server) {
        if (error) {
            *error = AFPCError(ENOMEM, nil);
        }
        return nil;
    }

    int ret = afp_server_connect(server, 1);
    if (ret < 0) {
        afp_server_remove(server);
        if (error) {
            *error = AFPCError(-ret, [NSString stringWithFormat:@"Couldn't connect to \"%@\".", host]);
        }
        return nil;
    }

    AFPCServerInfo *info = [[AFPCServerInfo alloc] initWithServer:server];
    afp_server_remove(server);
    return info;
}

@end
