//
//  AFPCErrors.h
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Return an NSError containing the given posix error code (in NSPOSIXErrorDomain) plus the message from the server
NSError *AFPCError(int code, NSString *_Nullable message);

NS_ASSUME_NONNULL_END
