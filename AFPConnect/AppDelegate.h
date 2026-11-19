//
//  AppDelegate.h
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-05.
//

#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuItemValidation>

@property (strong) SPUStandardUpdaterController *updaterController;
- (void)checkExtension;

@end

