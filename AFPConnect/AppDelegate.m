//
//  AppDelegate.m
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-05.
//

#import "AppDelegate.h"
#import "ACConnectWindowController.h"
#import "ACMounter.h"
#import "ACSettings.h"

#import "AFPCKeychain.h"

#import <FSKit/FSKit.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// target for the quit item so it stays enabled while an alert modal runs
@interface ACModalQuitTarget : NSObject
@end

@implementation ACModalQuitTarget

- (BOOL)worksWhenModal
{
    return YES;
}

- (void)terminate:(id)sender
{
    [NSApp terminate:sender];
}

@end

@interface AppDelegate () <NSMenuDelegate>
@end

@implementation AppDelegate {
    ACConnectWindowController *_connect;
    ACSettingsWindowController *_settings;
    ACModalQuitTarget *_quitTarget;
    BOOL _launched;
    NSMutableArray<NSURL *> *_pendingURLs;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    // clear out one-shot passwords that the mounter never read+deleted
    [AFPCKeychain sweepOneShotPasswordsOlderThan:300];
    [self enableQuitWhenModal];
    [self checkExtension];
    [self addVolumesMenu];

    _launched = YES;
    if (_pendingURLs.count) {
        [self application:NSApp openURLs:_pendingURLs];
        _pendingURLs = nil;
    } else {
        [self showConnect:nil];
    }
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app
{
    return YES;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag
{
    if (!flag) {
        [self showConnect:nil];
    }
    return YES;
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls
{
    if (!_launched) {
        _pendingURLs = _pendingURLs ?: [NSMutableArray array];
        [_pendingURLs addObjectsFromArray:urls];
        return;
    }
    for (NSURL *url in urls) {
        if ([url.scheme.lowercaseString isEqualToString:@"afp"]) {
            [self.connectController connectToAddress:url.absoluteString];
            break;
        }
    }
}

- (ACConnectWindowController *)connectController
{
    if (!_connect) {
        _connect = [[ACConnectWindowController alloc] init];
    }
    return _connect;
}

- (IBAction)showConnect:(id)sender
{
    [self.connectController showWindow:sender];
}

- (IBAction)showSettings:(id)sender
{
    if (!_settings) {
        _settings = [[ACSettingsWindowController alloc] init];
        [_settings.window center];
    }
    [_settings showWindow:sender];
}

- (void)enableQuitWhenModal
{
    NSMenu *appMenu = NSApp.mainMenu.itemArray.firstObject.submenu;
    NSInteger index = [appMenu indexOfItemWithTarget:nil andAction:@selector(terminate:)];
    if (index < 0) {
        return;
    }
    _quitTarget = [[ACModalQuitTarget alloc] init];
    [appMenu itemAtIndex:index].target = _quitTarget;

    // allow the quit AE sent by the Dock to go through as well
    [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self andSelector:@selector(handleQuitEvent:withReplyEvent:) forEventClass:kCoreEventClass andEventID:kAEQuitApplication];
}

- (void)handleQuitEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply
{
    [NSApp terminate:nil];
}

// the extension has to be turned on in System Settings before anything mounts
- (void)checkExtension
{
    // If there's a focus observer that ran this method, kill it (at least until the re-check handler recreates it)
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSApplicationDidBecomeActiveNotification object:nil];
    __weak __block ACConnectWindowController *connect = _connect;
    [ACMounter checkExtension:^(BOOL installed, BOOL enabled) {
        if (enabled) {
            return;
        }
        // kill any running connection
        [connect cancelConnection:self];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"AFPConnect needs your permission to mount shares";
        alert.informativeText = installed
            ? @"To use AFPConnect, enable the \"AFPFS\" extension in General > Login Items & Extensions > File System Extensions."
            : @"macOS hasn't registered AFPConnect's file system extension. Try moving AFPConnect to the Applications folder and opening it again.";
        if (installed) {
            [alert addButtonWithTitle:@"Open System Settings"];
            [alert addButtonWithTitle:@"Check Again"];
        } else {
            [alert addButtonWithTitle:@"Quit"];
        }
        NSModalResponse result = [alert runModal];
        if (result == NSAlertFirstButtonReturn) {
            if (installed) {
                // The user can't enable the extension without switching to System Settings,
                // meaning the app must lose and regain focus for them to enable it.
                // So schedule the next check for the next time the app gains focus,
                // rather than polling
                [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(checkExtension) name:NSApplicationDidBecomeActiveNotification object:nil];
                // Open System Settings, losing our focus
                [FSClient.sharedInstance openFileSystemExtensionsSettings];
            } else {
                // quit
                [NSApp terminate:nil];
            }
        } else if (installed) {
            // retry button clicked, run this method again
            [(AppDelegate *)[NSApp delegate] checkExtension];
        }
    }];
}

#pragma mark volumes menu

// a menu of the mounted afp volumes, before the window menu
- (void)addVolumesMenu
{
    NSMenu *main = NSApp.mainMenu;
    NSInteger index = [main indexOfItemWithTitle:@"Window"];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Volumes" action:nil keyEquivalent:@""];
    item.submenu = [[NSMenu alloc] initWithTitle:@"Volumes"];
    item.submenu.delegate = self;
    [main insertItem:item atIndex:index >= 0 ? index : main.numberOfItems];
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    [menu removeAllItems];
    NSDictionary<NSURL *, NSString *> *mounted = [ACMounter mountedVolumes];
    NSArray<NSURL *> *points = [mounted.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];
    if (!points.count) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"No AFP Volumes Mounted" action:nil keyEquivalent:@""];
        none.enabled = NO;
        [menu addItem:none];
        return;
    }
    for (NSURL *point in points) {
        NSString *host = [NSURL URLWithString:mounted[point]].host;
        NSString *title = host ? [NSString stringWithFormat:@"%@ on %@", point.lastPathComponent, host] : point.lastPathComponent;
        NSMenuItem *volume = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        // iconForFile: on the mount point blocks when the server hangs, and
        // this runs on the main thread, so every volume gets the generic icon
        volume.image = [[NSWorkspace.sharedWorkspace iconForContentType:UTTypeVolume] copy];
        volume.image.size = NSMakeSize(16, 16);
        volume.submenu = [[NSMenu alloc] initWithTitle:title];
        NSMenuItem *show = [volume.submenu addItemWithTitle:@"Reveal in Finder" action:@selector(showVolume:) keyEquivalent:@""];
        show.representedObject = point;
        show.target = self;
        NSMenuItem *eject = [volume.submenu addItemWithTitle:@"Unmount" action:@selector(unmountVolume:) keyEquivalent:@""];
        eject.representedObject = @[ point ];
        eject.target = self;
        [menu addItem:volume];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *all = [menu addItemWithTitle:@"Unmount All" action:@selector(unmountVolume:) keyEquivalent:@""];
    all.representedObject = points;
    all.target = self;
}

- (void)showVolume:(NSMenuItem *)sender
{
    revealShareInFinder(sender.representedObject);
}

- (void)unmountVolume:(NSMenuItem *)sender
{
    NSArray<NSURL *> *points = sender.representedObject;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSURL *point in points) {
            NSError *error = nil;
            if ([ACMounter unmount:point error:&error]) {
                continue;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = [NSString stringWithFormat:@"The volume \"%@\" couldn't be unmounted.", point.lastPathComponent];
                alert.informativeText = error.code == EBUSY ? @"One or more applications is still using the volume. Unmounting via the Finder may provide more detailed information." : error.localizedDescription;
                [alert runModal];
            });
        }
    });
}

- (IBAction)emailMe:(id)sender
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"mailto:benjamin@anachronist.io"]];
}
@end
