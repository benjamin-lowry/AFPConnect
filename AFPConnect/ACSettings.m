//
//  ACSettings.m
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-12.
//

#import "ACSettings.h"

#import "AFPCDefaults.h"
#import "AFPCEncoding.h"
#import "AFPCNames.h"

static NSString *const kTimeFix = @"TimeFix";
static NSString *const kRemember = @"RememberPasswords";
static NSString *const kRecents = @"RecentServers";
static NSString *const kFavorites = @"FavoriteServers";
static NSString *const kEncodings = @"ServerEncodings";
static const NSUInteger kMaxRecents = 10;

@implementation ACSettings

static NSString *knownTimeFix(id value)
{
    return [@[ @"zone", @"local" ] containsObject:value] ? value : @"all";
}

+ (NSString *)timeFix
{
    return knownTimeFix([AFPCSharedDefaults() stringForKey:kTimeFix]);
}

+ (BOOL)rememberPasswords
{
    return [AFPCSharedDefaults() boolForKey:kRemember];
}

+ (void)setRememberPasswords:(BOOL)remember
{
    [AFPCSharedDefaults() setBool:remember forKey:kRemember];
}

+ (NSArray<NSString *> *)recentServers
{
    return [AFPCSharedDefaults() stringArrayForKey:kRecents] ?: @[];
}

+ (void)setRecentServers:(NSArray<NSString *> *)servers
{
    [AFPCSharedDefaults() setObject:servers forKey:kRecents];
}

+ (NSArray<NSString *> *)favoriteServers
{
    return [AFPCSharedDefaults() stringArrayForKey:kFavorites] ?: @[];
}

+ (void)setFavoriteServers:(NSArray<NSString *> *)servers
{
    [AFPCSharedDefaults() setObject:servers forKey:kFavorites];
}

+ (NSString *)encodingForServer:(NSString *)server
{
    NSString *name = [AFPCSharedDefaults() dictionaryForKey:kEncodings][server.lowercaseString];
    return [AFPCEncoding.names containsObject:name] ? name : AFPCEncoding.defaultName;
}

+ (void)setEncoding:(NSString *)encoding forServer:(NSString *)server
{
    NSMutableDictionary *all = [[AFPCSharedDefaults() dictionaryForKey:kEncodings] mutableCopy]
                               ?: [NSMutableDictionary dictionary];
    all[server.lowercaseString] = encoding;
    [AFPCSharedDefaults() setObject:all forKey:kEncodings];
}

+ (void)addRecentServer:(NSString *)address
{
    NSMutableArray *recents = [self.recentServers mutableCopy];
    [recents removeObject:address];
    [recents insertObject:address atIndex:0];
    if (recents.count > kMaxRecents) {
        [recents removeObjectsInRange:NSMakeRange(kMaxRecents, recents.count - kMaxRecents)];
    }
    self.recentServers = recents;
}

+ (void)clearRecentServers
{
    self.recentServers = [[NSMutableArray alloc] init];
}

/// Validates availability of an NSMenuItem targeting an ACSettings selector. Currently only implemented for the "Clear Recent Servers" menu item (disabling it if no recent servers are saved).
+ (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    if (menuItem.action == @selector(clearRecentServers))
        return self.recentServers.count != 0;
    else
        return NO;
}

@end

@implementation ACDefaultsController

- (instancetype)init
{
    return [super initWithDefaults:AFPCSharedDefaults()
                     initialValues:@{ kTimeFix: @"all", AFPCConvertNamesKey: @YES }];
}

@end

@implementation ACTimeFixTransformer {
    NSString *_timeFix;
}

- (instancetype)initWithTimeFix:(NSString *)timeFix
{
    self = [super init];
    if (self) {
        _timeFix = [timeFix copy];
    }
    return self;
}

+ (Class)transformedValueClass
{
    return NSNumber.class;
}

+ (BOOL)allowsReverseTransformation
{
    return YES;
}

- (id)transformedValue:(id)value
{
    return @([knownTimeFix(value) isEqualToString:_timeFix]);
}

- (id)reverseTransformedValue:(id)value
{
    return [value boolValue] ? _timeFix : ACSettings.timeFix;
}

@end

@implementation ACSettingsWindowController

+ (void)initialize
{
    if (self == ACSettingsWindowController.class) {
        for (NSString *timeFix in @[ @"all", @"zone", @"local" ]) {
            NSString *name = [NSString stringWithFormat:@"ACTimeFix%@Transformer", timeFix.capitalizedString];
            [NSValueTransformer setValueTransformer:[[ACTimeFixTransformer alloc] initWithTimeFix:timeFix]
                                            forName:name];
        }
    }
}

- (instancetype)init
{
    return [super initWithWindowNibName:@"SettingsWindow"];
}

@end
