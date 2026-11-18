//
//  AFPCLibrary.m
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import "AFPCLibrary.h"
#import "AFPCInternal.h"

#import <os/lock.h>
#import <os/log.h>
#import <signal.h>

static os_log_t lib_log(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.benjaminlowry.AFPConnect.AFPCore", "libafpclient");
    });
    return log;
}

// Keys are token's address as NSNumber, so a pointer that isn't one of our tokens does not get dereferenced
static NSMutableDictionary<NSNumber *, NSMutableArray<NSString *> *> *collectors;
static os_unfair_lock collectors_lock = OS_UNFAIR_LOCK_INIT;

static void collect(void *priv, int loglevel, const char *message)
{
    if (!priv || loglevel > LOG_ERR) {
        return;
    }
    NSString *text = [NSString stringWithUTF8String:message];
    if (!text) {
        return;
    }
    os_unfair_lock_lock(&collectors_lock);
    [collectors[@((uintptr_t)priv)] addObject:text];
    os_unfair_lock_unlock(&collectors_lock);
}

static void log_message(void *priv, enum logtypes logtype, int loglevel, const char *message)
{
    collect(priv, loglevel, message);

    os_log_type_t type = OS_LOG_TYPE_DEFAULT;
    if (loglevel <= LOG_ERR) {
        type = OS_LOG_TYPE_ERROR;
    } else if (loglevel >= LOG_DEBUG) {
        type = OS_LOG_TYPE_DEBUG;
    } else if (loglevel >= LOG_INFO) {
        type = OS_LOG_TYPE_INFO;
    }
    // Messages can leak user/server names. Mark them private outside debug builds
#if DEBUG
    os_log_with_type(lib_log(), type, "%{public}s", message);
#else
    os_log_with_type(lib_log(), type, "%{private}s", message);
#endif
}

static int unmount_volume(struct afp_volume *volume)
{
    // We don't need to do anything, fskit handles this for us
    return 0;
}

static void forced_ending(void)
{
    os_log_error(lib_log(), "event loop ended");
}

static struct libafpclient client = {
    .unmount_volume = unmount_volume,
    .log_for_client = log_message,
    .forced_ending_hook = forced_ending,
};

@implementation AFPCLibrary

+ (void)start
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        collectors = [NSMutableDictionary dictionary];
        libafpclient_register(&client);
        init_uams();
        /* The loop thread sleeps in pselect until a socket opens which wakes it with SIGUSR2
           GCD worker threads block this signal by default so we need to manually unblock it
           (otherwise we just get killed by the 30 second timeout) */
        sigset_t wake, saved;
        sigemptyset(&wake);
        sigaddset(&wake, SIGUSR2);
        pthread_sigmask(SIG_UNBLOCK, &wake, &saved);
        afp_main_quick_startup(NULL);
        pthread_sigmask(SIG_SETMASK, &saved, NULL);
        afp_wait_for_started_loop();
        /* The libafpclient loop overwrites our SIGTERM and SIGINT handlers process-wide,
           replacing them with ones that only stop the loop.
           Reset the SIGTERM and SIGINT handlers so launchd can still end our process. */
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
    });
}

+ (NSArray<NSString *> *)collectMessages:(void (NS_NOESCAPE ^)(void *priv))block
{
    [self start];
    NSObject *token = [[NSObject alloc] init];
    NSMutableArray<NSString *> *messages = [NSMutableArray array];
    os_unfair_lock_lock(&collectors_lock);
    collectors[@((uintptr_t)(__bridge void *)token)] = messages;
    os_unfair_lock_unlock(&collectors_lock);

    block((__bridge void *)token);

    os_unfair_lock_lock(&collectors_lock);
    [collectors removeObjectForKey:@((uintptr_t)(__bridge void *)token)];
    NSArray *result = [messages copy];
    os_unfair_lock_unlock(&collectors_lock);
    return result;
}

@end
