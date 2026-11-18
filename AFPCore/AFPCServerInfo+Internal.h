//
//  AFPCServerInfo+Internal.h
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import "AFPCServerInfo.h"

struct afp_server;

@interface AFPCServerInfo ()

- (instancetype)initWithServer:(const struct afp_server *)server;

@end
