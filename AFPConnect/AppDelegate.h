//
//  AppDelegate.h
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-05.
//

#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (strong) IBOutlet SPUStandardUpdaterController *updaterController;
- (void)checkExtension;

@end

