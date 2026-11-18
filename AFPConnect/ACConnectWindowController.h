//
//  ACConnectWindowController.h
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-12.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Window controller for the "Connect to AFP Server" window.
@interface ACConnectWindowController : NSWindowController

/// Fills in the address and connects immediately.
- (void)connectToAddress:(NSString *)address;

/// Cancels the current connection.
- (IBAction)cancelConnection:(id)sender;
@end

NS_ASSUME_NONNULL_END
