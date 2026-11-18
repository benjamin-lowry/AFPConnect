//
//  ACDialogs.h
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-12.
//

#import <Cocoa/Cocoa.h>

@class AFPCVolumeInfo;

NS_ASSUME_NONNULL_BEGIN

@interface ACDialog : NSWindowController

/// Shows the dialog over parent and runs it as a modal once the current main queue block is done, then calls handler
- (void)beginForWindow:(NSWindow *)parent completionHandler:(void (^)(NSModalResponse response))handler;

- (IBAction)ok:(nullable id)sender;
- (IBAction)cancel:(nullable id)sender;

@end

/// AuthenticationDialog.xib
@interface ACAuthenticationDialog : ACDialog

@property (copy) NSString *serverName;
@property (copy, nullable) NSString *detail;
@property BOOL allowsGuest;
@property BOOL guest;
@property (copy) NSString *user;
@property (copy, readonly) NSString *password;
@property BOOL remember;
/// nil to hide the encoding dropdown box
@property (copy, nullable) NSString *encoding;

@end

/// VolumePickerDialog.xib
@interface ACVolumePickerDialog : ACDialog

@property (copy) NSString *serverName;
@property (copy) NSArray<AFPCVolumeInfo *> *volumes;
/// names of volumes that are already mounted. shown checked but greyed out
@property (copy) NSSet<NSString *> *mountedNames;
@property (readonly) NSArray<AFPCVolumeInfo *> *chosenVolumes;

@end

/// VolumePasswordDialog.xib
@interface ACVolumePasswordDialog : ACDialog

@property (copy) NSString *volumeName;
@property (copy) NSString *detail;
@property (copy, readonly) NSString *password;

@end

NS_ASSUME_NONNULL_END
