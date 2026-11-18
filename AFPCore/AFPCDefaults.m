//
//  AFPCDefaults.m
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import "AFPCDefaults.h"

// AFP_TEAM_ID gets set to the current provisioning team id by the xcconfig.
NSString *const AFPCAppGroup = @AFP_TEAM_ID ".com.benjaminlowry.AFPConnect";

/// Shared accessor for the AFPConnect app group defaults.
NSUserDefaults *AFPCSharedDefaults(void)
{
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:AFPCAppGroup];
    });
    return defaults;
}
