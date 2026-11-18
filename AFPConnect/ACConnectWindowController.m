//
//  ACConnectWindowController.m
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-12.
//

#import "AppDelegate.h"

#import "ACConnectWindowController.h"
#import "ACBrowser.h"
#import "ACDialogs.h"
#import "ACMounter.h"
#import "ACSettings.h"

#import "AFPCEncoding.h"
#import "AFPCKeychain.h"
#import "AFPCServerInfo.h"
#import "AFPCSession.h"

/// Represents the address a user is mounting, as the components of an AFP URL.
@interface ACAddress : NSObject
@property (copy) NSString *host;
@property uint16_t port;
@property (copy, nullable) NSString *user;
@property (copy, nullable) NSString *volume;
/// The Classic Mac OS encoding for filenames on an AFP 2 server. (Will be converted to an AFPCEncoding by AFPFS)
@property (copy) NSString *encoding;
@end

@implementation ACAddress

/// Creates a new ACAddress from a URL in the format ``host``, ``host:port`` or ``afp://[user@]host[:port][/volume]``
+ (instancetype)addressWithString:(NSString *)text
{
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) {
        return nil;
    }
    if (![text.lowercaseString hasPrefix:@"afp://"]) {
        text = [@"afp://" stringByAppendingString:text];
    }
    NSURLComponents *c = [NSURLComponents componentsWithString:text];
    if (!c.host.length || c.password) {
        return nil;
    }
    ACAddress *a = [[ACAddress alloc] init];
    a.host = c.host;
    a.port = c.port ? c.port.unsignedShortValue : 548;
    a.user = c.user.length ? [c.user componentsSeparatedByString:@";"].firstObject : nil;
    NSString *volume = [c.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    a.volume = volume.length ? volume : nil;
    return a;
}

/// Returns the server address normalized to ``afp://host[:port]``. This is what recents and favorites save for the server.
- (NSString *)serverString
{
    NSURLComponents *c = [[NSURLComponents alloc] init];
    c.scheme = @"afp";
    c.host = self.host;
    if (self.port != 548) {
        c.port = @(self.port);
    }
    return c.string;
}

@end

/// Represents a row in the favorites/Bonjour server list.
@interface ACRow : NSObject
@property (copy) NSString *title;
@property BOOL group;
/// Contents of the address field that will be filled in when this row is selected
@property (copy, nullable) NSString *address;
/// If this row represents a server found via Bonjour, a pointer to the ACService representing the Bonjour service. nil otherwise.
@property (nullable) ACService *service;
@end

@implementation ACRow
@end

@interface ACConnectWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDataSource, NSWindowDelegate, NSComboBoxDelegate>
@property (weak) IBOutlet NSComboBox *addressField;
@property (weak) IBOutlet NSTableView *serverTable;
@property (weak) IBOutlet NSButton *connectButton;
@property (weak) IBOutlet NSSegmentedControl *favlistButtons;
@property (weak) IBOutlet NSProgressIndicator *spinner;
@property (weak) IBOutlet NSMenu *actionMenu;
@end

// overrides undocumented private method to force the popup menu to appear immediately
@interface ImmediateMenuSegmentedCell : NSSegmentedCell
@end

@implementation ImmediateMenuSegmentedCell

- (double)_menuDelayTimeForSegment:(NSInteger)segment
{
    return 0.0;
}

@end

@implementation ACConnectWindowController {
    ACBrowser *_browser;
    NSArray<ACRow *> *_rows;
    NSError *_browseError;
    AFPCSession *_session;
    BOOL _busy;
    /// Attempt number, increased by cancelConnection; if we receive a result with a lower attempt number (indicating the result of a cancelled request) we ignore it
    NSUInteger _attempt;
    /// If YES, we have passed the point of no return for the mount process, i.e. cancellation is no longer possible
    BOOL _mounting;
}

- (instancetype)init
{
    self = [super initWithWindowNibName:@"ConnectToServerWindow"];
    if (self) {
        _browser = [[ACBrowser alloc] init];
        __weak ACConnectWindowController *weakSelf = self;
        _browser.changeHandler = ^(NSArray<ACService *> *services, NSError *error) {
            ACConnectWindowController *controller = weakSelf;
            if (!controller) {
                return;
            }
            controller->_browseError = error;
            [controller reloadRows];
        };
        [_browser start];
    }
    return self;
}

- (void)windowDidLoad
{
    [super windowDidLoad];
    _addressField.delegate = self;
    // Wire popup menu to ... button
    [_favlistButtons setMenu:_actionMenu forSegment:2];
    [_favlistButtons setShowsMenuIndicator:YES forSegment:2];
    [_favlistButtons setWidth:50 forSegment:2];
    // Wire "clear recent servers" class method to corresponding menu item
    [_actionMenu.itemArray[0] setTarget:[ACSettings class]];
    [_actionMenu.itemArray[0] setAction:@selector(clearRecentServers)];
    [self reloadRows];
}

- (void)windowWillClose:(NSNotification *)notification
{
    [self endSession];
}

- (IBAction)cancel:(id)sender
{
    [self.window performClose:sender];
}


#pragma mark - server list and address field

/// Only called if the user typed in the field themselves. Anything else that changes it (e.g. clicking on a table row) must call addressDidChange itself
- (void)controlTextDidChange:(NSNotification *)obj
{
    [self addressDidChange];
}

/// Called when a recent server is picked from the combo box, but the field's text has not yet been updated
- (void)comboBoxSelectionDidChange:(NSNotification *)notification
{
    NSInteger index = _addressField.indexOfSelectedItem;
    if (index >= 0 && index < (NSInteger)ACSettings.recentServers.count) {
        _addressField.stringValue = ACSettings.recentServers[(NSUInteger)index];
        [self addressDidChange];
    }
}

- (void)addressDidChange
{
    ACRow *row = [self selectedRow];
    if (row && ![row.address isEqualToString:_addressField.stringValue]) {
        [_serverTable deselectAll:nil];
    }
    [self updateButtons];
}

/// Set the state of the connect and favorite buttons based on the current contents of the address field.
- (void)updateButtons
{
    ACAddress *address = [ACAddress addressWithString:_addressField.stringValue];
    BOOL favorite = address && [self favoriteIndexForAddress:address] != NSNotFound;
    [_connectButton setEnabled:_busy ? !_mounting : _addressField.stringValue.length > 0];
    [_favlistButtons setEnabled:address && !favorite forSegment:0];
    [_favlistButtons setEnabled:favorite forSegment:1];
}

- (nullable ACRow *)selectedRow
{
    NSInteger index = _serverTable ? _serverTable.selectedRow : -1;
    return index >= 0 ? _rows[(NSUInteger)index] : nil;
}

- (void)reloadRows
{
    ACRow *selected = [self selectedRow];
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *favorites = ACSettings.favoriteServers;
    if (favorites.count) {
        ACRow *header = [[ACRow alloc] init];
        header.title = @"Favorite Servers";
        header.group = YES;
        [rows addObject:header];
        for (NSString *address in favorites) {
            ACRow *row = [[ACRow alloc] init];
            row.title = address;
            row.address = address;
            [rows addObject:row];
        }
    }
    ACRow *nearby = [[ACRow alloc] init];
    nearby.title = _browseError ? @"Nearby Servers (Local Network Access Unavailable)" : @"Nearby Servers";
    nearby.group = YES;
    [rows addObject:nearby];
    for (ACService *service in _browser.services) {
        ACRow *row = [[ACRow alloc] init];
        row.title = service.name;
        row.address = service.port == 548 ? service.host : [NSString stringWithFormat:@"%@:%u", service.host, service.port];
        row.service = service;
        [rows addObject:row];
    }
    _rows = rows;
    [_serverTable reloadData];
    // Keep selection on the same row even if it moves
    NSUInteger index = [rows indexOfObjectPassingTest:^BOOL(ACRow *row, NSUInteger i, BOOL *stop) {
        return !row.group && [row.address isEqualToString:selected.address] && !row.service == !selected.service;
    }];
    if (index != NSNotFound) {
        [_serverTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    } else {
        [_serverTable deselectAll:nil];
    }
    [self updateButtons];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return (NSInteger)_rows.count;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row
{
    return _rows[(NSUInteger)row].group;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
    return !_rows[(NSUInteger)row].group;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)index
{
    ACRow *row = _rows[(NSUInteger)index];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:row.group ? @"group" : @"server" owner:self];
    cell.textField.stringValue = row.title;
    cell.imageView.image = row.service ? [NSImage imageWithSystemSymbolName:@"desktopcomputer" accessibilityDescription:nil]
                                       : [NSImage imageWithSystemSymbolName:@"star" accessibilityDescription:nil];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    // note: deselection should keep the text in the combobox
    ACRow *row = [self selectedRow];
    if (row) {
        _addressField.stringValue = row.address;
    }
    [self updateButtons];
}

- (NSInteger)numberOfItemsInComboBox:(NSComboBox *)comboBox
{
    return (NSInteger)ACSettings.recentServers.count;
}

- (id)comboBox:(NSComboBox *)comboBox objectValueForItemAtIndex:(NSInteger)index
{
    return ACSettings.recentServers[(NSUInteger)index];
}

#pragma mark - favorites and recents handling

- (IBAction)favlistButtonsClicked:(id)sender
{
    switch ([sender selectedSegment]) {
        case 0:
            [self addFavorite];
            break;
        case 1:
            [self removeFavorite];
        /* we don't need to handle case 2 since the pop-up menu
         is already attached to the ... segment, so it will show up automatically */
    }
}

// host names are case-insensitive
- (NSUInteger)favoriteIndexForAddress:(ACAddress *)address
{
    NSString *server = address.serverString;
    return [ACSettings.favoriteServers indexOfObjectPassingTest:^BOOL(NSString *favorite, NSUInteger i, BOOL *stop) {
        return [favorite caseInsensitiveCompare:server] == NSOrderedSame;
    }];
}

- (void)addFavorite
{
    ACAddress *address = [ACAddress addressWithString:_addressField.stringValue];
    if (!address) {
        NSBeep();
        return;
    }
    if ([self favoriteIndexForAddress:address] == NSNotFound) {
        ACSettings.favoriteServers = [ACSettings.favoriteServers arrayByAddingObject:address.serverString];
        [self reloadRows];
    }
}

- (void)removeFavorite
{
    ACAddress *address = [ACAddress addressWithString:_addressField.stringValue];
    NSUInteger index = address ? [self favoriteIndexForAddress:address] : NSNotFound;
    if (index != NSNotFound) {
        NSMutableArray *favorites = [ACSettings.favoriteServers mutableCopy];
        [favorites removeObjectAtIndex:index];
        ACSettings.favoriteServers = favorites;
        [self reloadRows];
    }
}

#pragma mark - connecting

- (void)setBusy:(BOOL)busy
{
    _busy = busy;
    _mounting &= busy;
    // while busy the button's function changes to cancel
    // keyEquivalent is cleared so enter won't cancel the connection accidentally
    _connectButton.title = busy ? @"Cancel" : @"Connect";
    _connectButton.action = busy ? @selector(cancelConnection:) : @selector(connect:);
    _connectButton.keyEquivalent = busy ? @"" : @"\r";
    _addressField.enabled = !busy;
    busy ? [_spinner startAnimation:nil] : [_spinner stopAnimation:nil];
    [self updateButtons];
}

// The blocking calls can't be interrupted, so "cancelling" them just throws away the results by incrementing our attempt counter
- (IBAction)cancelConnection:(id)sender
{
    _attempt++;
    _session = nil;
    [self setBusy:NO];
}

- (void)connectToAddress:(NSString *)address
{
    [self showWindow:nil];
    _addressField.stringValue = address;
    [self addressDidChange];
    [self connect:nil];
}

- (IBAction)connect:(id)sender
{
    // sanity check that our fskit ext is still enabled
    [(AppDelegate *)[NSApp delegate] checkExtension];
    // bail out early if the address is empty
    if (_addressField.stringValue.length == 0) return;
    // Failsafe to make sure we don't open another modal if a modal or sheet is already rendering
    if (_busy || self.window.attachedSheet || NSApp.modalWindow) {
        if (self.window.attachedSheet || NSApp.modalWindow) {
            NSBeep();
        }
        return;
    }
    ACAddress *address = [ACAddress addressWithString:_addressField.stringValue];
    if (!address) {
        [self showError:@"Invalid AFP server address" detail:@"Enter a hostname like server.local, an IP address like 10.0.1.1, or a full AFP address like afp://server.local/Volume." localNetwork:NO afpfsOnly:NO];
        return;
    }
    // Grab service.name from the selected row, so if this is a Bonjour server,
    // its service name will be shown in any potential error dialog
    [self probe:address displayName:[self selectedRow].service.name];
}

/// Read the server's info without logging in. displayName will be used as the name of the server if an error dialog is shown.
- (void)probe:(ACAddress *)address displayName:(NSString *)displayName
{
    [self setBusy:YES];
    /* Decode the server name using whatever encoding the user previously chose
       (if they've connected to this server before) */
    address.encoding = [ACSettings encodingForServer:address.serverString];
    [AFPCEncoding useEncodingNamed:address.encoding];
    NSUInteger attempt = _attempt;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        AFPCServerInfo *info = [AFPCServerInfo probeHost:address.host port:address.port error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (attempt != self->_attempt) {
                return;
            }
            [self setBusy:NO];
            if (!info) {
                [self showError:[NSString stringWithFormat:@"There was a problem connecting to the server \"%@\".",
                                    displayName ?: address.host]
                         detail:error.localizedDescription localNetwork:error.code == EHOSTUNREACH afpfsOnly:NO];
                return;
            }
            [ACSettings addRecentServer:address.serverString];
            NSString *saved = address.user ? [AFPCKeychain passwordForHost:address.host user:address.user] : nil;
            if (saved) {
                [self login:address info:info user:address.user password:saved remember:YES];
            } else {
                [self askLogin:address info:info];
            }
        });
    });
}

- (void)askLogin:(ACAddress *)address info:(AFPCServerInfo *)info
{
    ACAuthenticationDialog *dialog = [[ACAuthenticationDialog alloc] init];
    dialog.serverName = info.name;
    dialog.allowsGuest = info.supportsGuest;
    dialog.guest = info.supportsGuest && !address.user;
    dialog.user = address.user ?: NSFullUserName();
    dialog.remember = ACSettings.rememberPasswords;
    if (!info.versions.count || info.versions.lastObject.intValue < 30) {
        dialog.encoding = address.encoding;
    }
    [dialog beginForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) {
            return;
        }
        ACSettings.rememberPasswords = dialog.remember;
        if (dialog.encoding) {
            address.encoding = dialog.encoding;
            [ACSettings setEncoding:address.encoding forServer:address.serverString];
        }
        BOOL guest = dialog.guest;
        [self login:address info:info user:guest ? nil : dialog.user password:guest ? nil : dialog.password
           remember:!guest && dialog.remember];
    }];
}

/// Logs in to verify the password and list volumes (the AFPFS extension will log in again itself).
- (void)login:(ACAddress *)address info:(AFPCServerInfo *)info user:(NSString *)user password:(NSString *)password
     remember:(BOOL)remember
{
    [self setBusy:YES];
    NSUInteger attempt = _attempt;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        [AFPCEncoding useEncodingNamed:address.encoding];
        AFPCSession *session = [AFPCSession connectToHost:address.host port:address.port user:user password:password
                                             keepPassword:NO error:&error];
        // Look it up here since it can block waiting on dns
        NSDictionary<NSString *, NSURL *> *mounted = session ? [ACMounter mountPointsOnHost:address.host port:address.port] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (attempt != self->_attempt) {
                closeSession(session);
                return;
            }
            [self setBusy:NO];
            if (!session) {
                if (error.code == EACCES || error.code == EAUTH) {
                    [self askLogin:address info:info];
                } else {
                    [self showError:[NSString stringWithFormat:@"Unable to log into \"%@\".", info.name]
                             detail:error.localizedDescription localNetwork:error.code == EHOSTUNREACH afpfsOnly:NO];
                }
                return;
            }
            [self endSession];
            self->_session = session;
            ACMountRequest *request = [[ACMountRequest alloc] init];
            request.host = address.host;
            request.port = address.port;
            request.user = user;
            request.password = password;
            request.remember = remember;
            request.timefix = ACSettings.timeFix;
            request.encoding = address.encoding;
            if (!address.volume) {
                [self pickVolumes:session.volumes mounted:mounted request:request serverName:info.name];
                return;
            }
            for (AFPCVolumeInfo *v in session.volumes) {
                if ([v.name isEqualToString:address.volume]) {
                    NSURL *point = mounted[v.name];
                    if (point) {
                        // same behavior as finder, remounting a volume just reveals it
                        [self endSession];
                        revealShareInFinder(point);
                        [self.window orderOut:nil];
                        return;
                    }
                    [self checkVolumes:@[ v ] request:request serverName:info.name passwords:@[] message:nil];
                    return;
                }
            }
            [self endSession];
            [self showError:[NSString stringWithFormat:@"\"%@\" has no volume named \"%@\".", info.name, address.volume]
                     detail:nil localNetwork:NO afpfsOnly:NO];
        });
    });
}

static void closeSession(AFPCSession *session)
{
    if (session) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [session close];
        });
    }
}

- (void)endSession
{
    closeSession(_session);
    _session = nil;
}

- (void)pickVolumes:(NSArray<AFPCVolumeInfo *> *)volumes mounted:(NSDictionary<NSString *, NSURL *> *)mounted request:(ACMountRequest *)request serverName:(NSString *)serverName
{
    if (!volumes.count) {
        [self endSession];
        if (!request.user)
            [self showError:[NSString stringWithFormat:@"There are no shared volumes on \"%@\" accessible to guests.", serverName] detail:nil localNetwork:NO afpfsOnly:NO];
        else
            [self showError:[NSString stringWithFormat:@"There are no shared volumes on \"%@\" accessible to your user account.", serverName] detail:nil localNetwork:NO afpfsOnly:NO];
        return;
    }
    ACVolumePickerDialog *dialog = [[ACVolumePickerDialog alloc] init];
    dialog.serverName = serverName;
    dialog.volumes = volumes;
    dialog.mountedNames = [NSSet setWithArray:mounted.allKeys];
    [dialog beginForWindow:self.window completionHandler:^(NSModalResponse response) {
        NSArray<AFPCVolumeInfo *> *chosen = dialog.chosenVolumes;
        if (response != NSModalResponseOK || !chosen.count) {
            [self endSession];
            return;
        }
        [self checkVolumes:chosen request:request serverName:serverName passwords:@[] message:nil];
    }];
}

/// Asks for and checks each provided volume's password, then mounts them all
- (void)checkVolumes:(NSArray<AFPCVolumeInfo *> *)volumes request:(ACMountRequest *)request
          serverName:(NSString *)serverName passwords:(NSArray *)passwords message:(NSString *)message
{
    if (passwords.count == volumes.count) {
        [self endSession];
        NSMutableArray *requests = [NSMutableArray array];
        for (NSUInteger i = 0; i < volumes.count; i++) {
            ACMountRequest *r = [[ACMountRequest alloc] init];
            r.host = request.host;
            r.port = request.port;
            r.user = request.user;
            r.password = request.password;
            r.remember = request.remember;
            r.timefix = request.timefix;
            r.encoding = request.encoding;
            r.volume = volumes[i].name;
            r.volumePassword = passwords[i] == NSNull.null ? nil : passwords[i];
            [requests addObject:r];
        }
        [self mountVolumes:requests serverName:serverName];
        return;
    }
    AFPCVolumeInfo *volume = volumes[passwords.count];
    if (!volume.hasPassword) {
        [self checkVolumes:volumes request:request serverName:serverName
                 passwords:[passwords arrayByAddingObject:NSNull.null] message:nil];
        return;
    }
    [self askVolumePassword:volume message:message completion:^(NSString *password) {
        if (!password) {
            [self endSession];
            return;
        }
        AFPCSession *session = self->_session;
        [self setBusy:YES];
        NSUInteger attempt = self->_attempt;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            BOOL ok = [session openVolumeNamed:volume.name password:password error:&error] != NULL;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (attempt != self->_attempt) {
                    closeSession(session);
                    return;
                }
                [self setBusy:NO];
                if (self->_session != session) {
                    return;
                }
                if (ok) {
                    [self checkVolumes:volumes request:request serverName:serverName
                             passwords:[passwords arrayByAddingObject:password] message:nil];
                } else if (error.code == EAUTH) {
                    [self checkVolumes:volumes request:request serverName:serverName passwords:passwords
                               message:@"The password is incorrect. Try again."];
                } else {
                    [self endSession];
                    [self showError:[NSString stringWithFormat:@"The volume \"%@\" couldn't be opened.", volume.name]
                             detail:error.localizedFailureReason ?: error.localizedDescription localNetwork:NO afpfsOnly:NO];
                }
            });
        });
    }];
}

- (void)askVolumePassword:(AFPCVolumeInfo *)volume message:(NSString *)message completion:(void (^)(NSString *))completion
{
    ACVolumePasswordDialog *dialog = [[ACVolumePasswordDialog alloc] init];
    dialog.volumeName = volume.name;
    if (message)
        dialog.detail = message;
    [dialog beginForWindow:self.window completionHandler:^(NSModalResponse response) {
        completion(response == NSModalResponseOK ? dialog.password : nil);
    }];
}

- (void)mountVolumes:(NSArray<ACMountRequest *> *)requests serverName:(NSString *)serverName
{
    if (!requests.count) {
        return;
    }
    [self setBusy:YES];
    _mounting = YES;
    [self updateButtons];
    ACMountRequest *request = requests.firstObject;
    NSArray *rest = [requests subarrayWithRange:NSMakeRange(1, requests.count - 1)];
    [ACMounter mount:request completion:^(NSURL *point, NSError *error) {
        [self setBusy:NO];
        if (point) {
            revealShareInFinder(point);
            if (!rest.count) {
                [self.window orderOut:nil];
            }
            [self mountVolumes:rest serverName:serverName];
            return;
        }
        // If we got this far before hitting EHOSTUNREACH, the app can reach the server but AFPFS can't, so it probably doesn't have local network perms
        BOOL localNetwork = error.code == EHOSTUNREACH;
        void (^show)(void) = ^{
            [self showError:[NSString stringWithFormat:@"The volume \"%@\" couldn't be mounted.", request.volume]
                     detail:localNetwork ? @"AFPConnect's file system extension couldn't reach the server."
                                         : (error.localizedFailureReason ?: error.localizedDescription)
               localNetwork:localNetwork afpfsOnly:localNetwork];
        };
        if ([ACMounter isExtensionLaunchFailure:error]) {
            // duplicate copy of the AFPFS extension conflicting with notarization is the only cause I know of for this error
            // if we find a duplicate, tell the user to delete it
            // if we don't find a duplicate, show the generic vague message so we don't give the user bad advice
            [ACMounter findDuplicates:^(NSArray<NSURL *> *duplicates) {
                if (duplicates.count)
                    [self showDuplicates:duplicates];
                else
                    show();
            }];
            return;
        }
        show();
    }];
}

- (void)showDuplicates:(NSArray<NSURL *> *)duplicates
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = duplicates.count == 1
        ? @"Another copy of AFPConnect is conflicting with share mounting"
        : @"Other copies of AFPConnect are conflicting with share mounting";
    NSArray<NSString *> *paths = [duplicates valueForKey:@"path"];
    alert.informativeText = [NSString stringWithFormat:@"Move %@ to the Trash, then try again.\n\n%@",
                             duplicates.count == 1 ? @"this copy" : @"these copies", [paths componentsJoinedByString:@"\n"]];
    [alert addButtonWithTitle:@"Show in Finder"];
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:duplicates];
        }
    }];
}

- (void)showError:(NSString *)message detail:(NSString *)detail localNetwork:(BOOL)localNetwork afpfsOnly:(BOOL)afpfsOnly
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = detail ?: @"";
    [alert addButtonWithTitle:@"OK"];
    if (localNetwork) {
        if (!afpfsOnly)
            alert.informativeText = [alert.informativeText stringByAppendingString:
                @" Make sure \"AFPConnect\" and \"AFPFS\" are enabled in System Settings > Privacy & Security > Local Network. If they already are, try restarting your Mac."];
        else
            alert.informativeText = [alert.informativeText stringByAppendingString:
                @" Make sure \"AFPFS\" is enabled in System Settings > Privacy & Security > Local Network. If it already is, try restarting your Mac."];
        [alert addButtonWithTitle:@"Open Privacy Settings"];
    }
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertSecondButtonReturn) {
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
                @"x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"]];
        }
    }];
}

@end
