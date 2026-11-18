//
//  ACSettings.h
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-12.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ACSettings : NSObject

/// "all", "zone" or "local", passed to the extension as -o timefix=
@property (class, readonly, copy) NSString *timeFix;
@property (class) BOOL rememberPasswords;

/// Recent server addresses as typed, in chronological order
@property (class, copy) NSArray<NSString *> *recentServers;
/// Favorite server addresses as typed, in order added
@property (class, copy) NSArray<NSString *> *favoriteServers;
+ (void)addRecentServer:(NSString *)address;

/// Encoding last used with server; if server never connected to, whatever the default is for this Mac's language
+ (NSString *)encodingForServer:(NSString *)server;
+ (void)setEncoding:(NSString *)encoding forServer:(NSString *)server;
+ (void)clearRecentServers;

+ (BOOL)validateMenuItem:(NSMenuItem *)menuItem;

@end

/// Shared app group defaults controller for the settings dialog's bindings
@interface ACDefaultsController : NSUserDefaultsController
@end

/// On/off state for the time fix radio buttons in the settings dialog
@interface ACTimeFixTransformer : NSValueTransformer
- (instancetype)initWithTimeFix:(NSString *)timeFix NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// SettingsWindow.xib
@interface ACSettingsWindowController : NSWindowController
@end

NS_ASSUME_NONNULL_END
