//
//  ACDialogs.m
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-12.
//

#import "ACDialogs.h"

#import "AFPCEncoding.h"
#import "AFPCSession.h"

@implementation ACDialog

- (void)beginForWindow:(NSWindow *)parent completionHandler:(void (^)(NSModalResponse))handler
{
    NSWindow *window = self.window;
    [window layoutIfNeeded];
    [window setContentSize:window.contentView.fittingSize];
    if (parent.visible) {
        NSRect frame = window.frame;
        frame.origin.x = round(NSMidX(parent.frame) - NSWidth(frame) / 2);
        frame.origin.y = round(NSMidY(parent.frame) - NSHeight(frame) / 2);
        [window setFrame:[window constrainFrameRect:frame toScreen:parent.screen] display:NO];
    } else {
        [window center];
    }
    [NSRunLoop.mainRunLoop performBlock:^{
        NSModalResponse response = [NSApp runModalForWindow:self.window];
        [self.window orderOut:nil];
        handler(response);
    }];
}

- (IBAction)ok:(id)sender
{
    [NSApp stopModalWithCode:NSModalResponseOK];
}

- (IBAction)cancel:(id)sender
{
    [NSApp stopModalWithCode:NSModalResponseCancel];
}

@end

#pragma mark login

@interface ACAuthenticationDialog ()
@property (weak) IBOutlet NSTextField *messageField;
@property (weak) IBOutlet NSTextField *detailField;
@property (weak) IBOutlet NSGridView *grid;
@property (weak) IBOutlet NSButton *guestButton;
@property (weak) IBOutlet NSButton *registeredButton;
@property (weak) IBOutlet NSTextField *nameField;
@property (weak) IBOutlet NSSecureTextField *passwordField;
@property (weak) IBOutlet NSButton *rememberButton;
@property (weak) IBOutlet NSPopUpButton *encodingPopUp;
@property (weak) IBOutlet NSGridRow *nameRow;
@property (weak) IBOutlet NSGridRow *passwordRow;
@property (weak) IBOutlet NSGridRow *rememberRow;
@property (weak) IBOutlet NSGridRow *encodingRow;
@property (copy, readwrite) NSString *password;
@end

@implementation ACAuthenticationDialog

- (instancetype)init
{
    self = [super initWithWindowNibName:@"AuthenticationDialog"];
    if (self) {
        _serverName = @"";
        _detail = @"";
        _user = @"";
        _password = @"";
    }
    return self;
}

- (void)windowDidLoad
{
    [super windowDidLoad];
    self.messageField.stringValue = [NSString stringWithFormat:@"Enter your name and password for the server \"%@\".", self.serverName];
    if (self.detail)
        self.detailField.stringValue = self.detail;
    self.guestButton.enabled = self.allowsGuest;
    self.nameField.stringValue = self.user;
    self.rememberButton.state = self.remember ? NSControlStateValueOn : NSControlStateValueOff;
    // Encoding prompt for AFP 2 servers; copying what 10.4 does
    if (self.encoding) {
        [self.encodingPopUp removeAllItems];
        for (NSString *e in AFPCEncoding.names) {
            [self.encodingPopUp addItemWithTitle:[AFPCEncoding displayNameFor:e]];
            self.encodingPopUp.lastItem.representedObject = e;
        }
        [self.encodingPopUp selectItemAtIndex:(NSInteger)[AFPCEncoding.names indexOfObject:self.encoding]];
    } else {
        self.encodingRow.hidden = YES;
    }
    [self loginKindChanged:nil];
}

/// Sent by the radio buttons to switch the name and password fields on or off
- (IBAction)loginKindChanged:(id)sender
{
    BOOL guest = self.guestButton.state == NSControlStateValueOn;
    self.nameRow.hidden = guest;
    self.passwordRow.hidden = guest;
    self.rememberRow.hidden = guest;
}

- (IBAction)ok:(id)sender
{
    self.guest = self.guestButton.state == NSControlStateValueOn;
    self.user = self.nameField.stringValue;
    self.password = self.passwordField.stringValue;
    self.remember = self.rememberButton.state == NSControlStateValueOn;
    if (self.encoding) {
        self.encoding = self.encodingPopUp.selectedItem.representedObject;
    }
    [super ok:sender];
}

@end

#pragma mark - volume picker

@interface ACVolumeCellView : NSTableCellView
@property (weak) IBOutlet NSButton *checkbox;
@end

@implementation ACVolumeCellView
@end

@interface ACVolumePickerDialog () <NSTableViewDataSource, NSTableViewDelegate>
@property (weak) IBOutlet NSTextField *messageField;
@property (weak) IBOutlet NSTableView *table;
@property (weak) IBOutlet NSButton *okButton;
@end

@implementation ACVolumePickerDialog {
    /// Rows of the volumes checked for mounting
    NSMutableIndexSet *_checked;
}

- (instancetype)init
{
    self = [super initWithWindowNibName:@"VolumePickerDialog"];
    if (self) {
        _serverName = @"";
        _volumes = @[];
        _mountedNames = [NSSet set];
        _checked = [NSMutableIndexSet indexSet];
    }
    return self;
}

- (void)windowDidLoad
{
    [super windowDidLoad];
    self.messageField.stringValue = [NSString stringWithFormat:@"Select the volumes you want to mount on \"%@\":", self.serverName];
    // If only one volume isn't mounted, start with it checked
    NSIndexSet *open = [self.volumes indexesOfObjectsPassingTest:^BOOL(AFPCVolumeInfo *v, NSUInteger i, BOOL *stop) {
        return ![self.mountedNames containsObject:v.name];
    }];
    if (open.count == 1) {
        [_checked addIndexes:open];
    }
    [self.table reloadData];
    [self update];
}

- (NSArray<AFPCVolumeInfo *> *)chosenVolumes
{
    return [self.volumes objectsAtIndexes:_checked];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return (NSInteger)self.volumes.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    ACVolumeCellView *cell = [tableView makeViewWithIdentifier:@"volume" owner:self];
    AFPCVolumeInfo *volume = self.volumes[(NSUInteger)row];
    // Don't re-mount a volume with the same url (fskit will return EBUSY if we do)
    BOOL mounted = [self.mountedNames containsObject:volume.name];
    cell.checkbox.title = volume.name;
    cell.checkbox.enabled = !mounted;
    cell.checkbox.state = mounted || [_checked containsIndex:(NSUInteger)row] ? NSControlStateValueOn : NSControlStateValueOff;
    cell.checkbox.toolTip = mounted ? @"Already mounted" : nil;
    return cell;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
    return NO;
}

- (IBAction)volumeToggled:(NSButton *)sender
{
    NSInteger row = [self.table rowForView:sender];
    if (row < 0) {
        return;
    }
    if (sender.state == NSControlStateValueOn) {
        [_checked addIndex:(NSUInteger)row];
    } else {
        [_checked removeIndex:(NSUInteger)row];
    }
    [self update];
}

/// Enable the ok button only if at least one volume checked
- (void)update
{
    self.okButton.enabled = _checked.count > 0;
}

@end

#pragma mark - volume password

@interface ACVolumePasswordDialog ()
@property (weak) IBOutlet NSTextField *messageField;
@property (weak) IBOutlet NSTextField *detailField;
@property (weak) IBOutlet NSSecureTextField *passwordField;
@property (copy, readwrite) NSString *password;
@end

@implementation ACVolumePasswordDialog

- (instancetype)init
{
    self = [super initWithWindowNibName:@"VolumePasswordDialog"];
    if (self) {
        _volumeName = @"";
        _detail = @"";
        _password = @"";
    }
    return self;
}

- (void)windowDidLoad
{
    [super windowDidLoad];
    self.messageField.stringValue = [NSString stringWithFormat:@"Enter the password for the volume \"%@\".", self.volumeName];
    self.detailField.stringValue = self.detail;
}

- (IBAction)ok:(id)sender
{
    self.password = self.passwordField.stringValue;
    [super ok:sender];
}

@end
