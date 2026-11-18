//
//  AFPCErrors.m
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import "AFPCErrors.h"

NSError *AFPCError(int code, NSString *message)
{
    NSDictionary *info = message.length ? @{ NSLocalizedDescriptionKey: message } : nil;
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:info];
}
