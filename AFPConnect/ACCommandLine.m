//
//  ACCommandLine.m
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-05.
//

#import "ACCommandLine.h"
#import "ACMounter.h"
#import "ACSettings.h"

#import "AFPCEncoding.h"
#import "AFPCKeychain.h"
#import "AFPCSession.h"

#import <readpassphrase.h>

static void usage(void)
{
    fprintf(stderr, "usage: AFPConnect --mount afp://[user@]host[:port]/volume [--password-stdin] [--remember] [--timefix all|zone|local] [--encoding name]\n");
}

BOOL ACIsCommandLine(int argc, const char *argv[])
{
    return argc > 1 && memcmp(argv[1], "--", 2) == 0 && memcmp(argv[1], "-NS", 3) != 0;
}

static NSString *readPassword(BOOL fromStdin, NSString *prompt)
{
    char buf[256];
    if (fromStdin) {
        if (!fgets(buf, sizeof(buf), stdin)) {
            return nil;
        }
        buf[strcspn(buf, "\n")] = '\0';
    } else if (!readpassphrase(prompt.UTF8String, buf, sizeof(buf), RPP_REQUIRE_TTY)) {
        return nil;
    }
    NSString *password = @(buf);
    memset(buf, 0, sizeof(buf));
    return password;
}

/// Sanitize a name from the server by replacing terminal escape characters with backslash codes
static NSString *printable(NSString *name)
{
    NSMutableString *out = [NSMutableString string];
    [name enumerateSubstringsInRange:NSMakeRange(0, name.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *c, NSRange r, NSRange e, BOOL *stop) {
        unichar u = [c characterAtIndex:0];
        if (c.length == 1 && (u < 0x20 || u == 0x7f || (u >= 0x80 && u < 0xa0))) {
            [out appendFormat:@"\\%03o", u];
        } else {
            [out appendString:c];
        }
    }];
    return out;
}

// Parse host/port/user/volume out of an AFP URL
static BOOL parseURL(NSString *text, NSString **host, uint16_t *port, NSString **user, NSString **volume)
{
    NSURLComponents *c = [NSURLComponents componentsWithString:text];
    if (!c || [c.scheme caseInsensitiveCompare:@"afp"] != NSOrderedSame || !c.host.length || c.password) {
        return NO;
    }
    *host = c.host;
    *port = c.port ? c.port.unsignedShortValue : 548;
    *user = c.user.length ? c.user : nil;
    *volume = [c.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    return YES;
}

/// Converts an NSError to a printable NSString with leading/trailing whitespace/newlines removed
static NSString *errorText(NSError *error)
{
    NSString *reason = error.localizedFailureReason ?: error.localizedDescription;
    return [reason stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

int ACRunCommandLine(int argc, const char *argv[])
{
    NSString *command = @(argv[1]);
    if ([command isEqualToString:@"--list-encodings"]) {
        for (NSString *name in AFPCEncoding.names) {
            printf("%-18s %s\n", name.UTF8String, [AFPCEncoding displayNameFor:name].UTF8String);
        }
        return 0;
    }
    NSString *target = argc > 2 ? @(argv[2]) : nil;
    BOOL passwordStdin = NO, remember = NO;
    NSString *timefix = nil, *encoding = nil;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            usage();
            return 0;
        }
        if (!strcmp(argv[i], "--password-stdin")) {
            passwordStdin = YES;
        } else if (!strcmp(argv[i], "--remember")) {
            remember = YES;
        } else if (!strcmp(argv[i], "--timefix") && i + 1 < argc) {
            timefix = @(argv[++i]);
            if (![@[ @"all", @"zone", @"local" ] containsObject:timefix]) {
                usage();
                return 2;
            }
        } else if (!strcmp(argv[i], "--encoding") && i + 1 < argc) {
            encoding = @(argv[++i]);
        } else {
            usage();
            return 2;
        }
    }
    if (!target) {
        usage();
        return 2;
    }

    if ([command isEqualToString:@"--unmount"]) {
        NSError *error = nil;
        if (![ACMounter unmount:[NSURL fileURLWithPath:target] error:&error]) {
            fprintf(stderr, "unmount failed: %s\n", errorText(error).UTF8String);
            return 1;
        }
        return 0;
    }

    NSString *host, *user, *volume;
    uint16_t port;
    if (!parseURL(target, &host, &port, &user, &volume)) {
        fprintf(stderr, "not an afp url: %s\n(if you're putting a password in the url, remove it)\n", target.UTF8String);
        return 2;
    }

    NSString *server = port == 548 ? [@"afp://" stringByAppendingString:host.lowercaseString]
                                   : [NSString stringWithFormat:@"afp://%@:%u", host.lowercaseString, port];
    if (encoding && ![AFPCEncoding.names containsObject:encoding]) {
        fprintf(stderr, "unknown encoding %s (see --list-encodings)\n", encoding.UTF8String);
        return 2;
    }
    if (encoding) {
        [ACSettings setEncoding:encoding forServer:server];
    }
    encoding = encoding ?: [ACSettings encodingForServer:server];
    [AFPCEncoding useEncodingNamed:encoding];

    if ([command isEqualToString:@"--forget-password"]) {
        [AFPCKeychain deletePasswordForHost:host user:user ?: @""];
        return 0;
    }

    NSString *password = nil;
    if (user) {
        BOOL saving = [command isEqualToString:@"--save-password"];
        password = passwordStdin ? readPassword(YES, nil)
                                 : saving ? nil : [AFPCKeychain passwordForHost:host user:user];
        if (!password && !passwordStdin) {
            password = readPassword(NO, [NSString stringWithFormat:@"Enter password for %@ on %@: ", user, host]);
        }
        if (!password) {
            fprintf(stderr, "fatal: no password\n");
            return 1;
        }
    }

    if ([command isEqualToString:@"--save-password"]) {
        NSError *error = nil;
        if (!user || ![AFPCKeychain savePassword:password forHost:host user:user error:&error]) {
            fprintf(stderr, "fatal: couldn't save the password: %s\n", user ? errorText(error).UTF8String : "the url has no user");
            return 1;
        }
        return 0;
    }

    // attempt a login here to make sure the password is correct so we don't hang fskit trying to log in with a wrong password
    NSError *error = nil;
    AFPCSession *session = [AFPCSession connectToHost:host port:port user:user password:password
                                         keepPassword:NO error:&error];
    if (!session) {
        fprintf(stderr, "couldn't log in: %s\n",
                error.code == EACCES || error.code == EAUTH ? "incorrect username or password" : errorText(error).UTF8String);
        return 1;
    }
    NSArray<AFPCVolumeInfo *> *volumes = session.volumes;

    if ([command isEqualToString:@"--list-volumes"]) {
        [session close];
        for (AFPCVolumeInfo *v in volumes) {
            printf("%s%s\n", printable(v.name).UTF8String, v.hasPassword ? " (password)" : "");
        }
        return 0;
    }

    if ([command isEqualToString:@"--mount"]) {
        AFPCVolumeInfo *info = nil;
        for (AFPCVolumeInfo *v in volumes) {
            if ([v.name isEqualToString:volume]) {
                info = v;
            }
        }
        if (!info) {
            [session close];
            fprintf(stderr, "server has no volume named \"%s\"\n", printable(volume).UTF8String);
            return 1;
        }
        NSString *volumePassword = nil;
        if (info.hasPassword) {
            volumePassword = readPassword(passwordStdin,
                                          [NSString stringWithFormat:@"Enter password for volume %@: ", volume]);
            if (!volumePassword || ![session openVolumeNamed:volume password:volumePassword error:&error]) {
                [session close];
                fprintf(stderr, "couldn't open the volume: %s\n", volumePassword ? errorText(error).UTF8String : "no password");
                return 1;
            }
        }
        [session close];
        ACMountRequest *request = [[ACMountRequest alloc] init];
        request.host = host;
        request.port = port;
        request.user = user;
        request.volume = volume;
        request.password = password;
        request.remember = remember;
        request.volumePassword = volumePassword;
        request.timefix = timefix;
        request.encoding = encoding;
        __block int status = 1;
        [ACMounter mount:request completion:^(NSURL *point, NSError *mountError) {
            if (point) {
                printf("%s\n", point.path.UTF8String);
                status = 0;
            } else {
                fprintf(stderr, "mount failed: %s\n", errorText(mountError).UTF8String);
            }
            CFRunLoopStop(CFRunLoopGetMain());
        }];
        // LET THE BASS GO
        CFRunLoopRun();
        return status;
    }

    usage();
    return 2;
}
