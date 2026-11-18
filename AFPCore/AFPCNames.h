//
//  AFPCNames.h
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-08.
//

// handles ascii normalization of non-ascii volume names for mount points
// (since fskit can't mount to a path containing non-ascii chars)

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The key for "Transliterate non-ASCII shared names in mount paths" in the shared defaults (AFPCDefaults.h)
extern NSString *const AFPCConvertNamesKey;

/// Whether the "Transliterate non-ASCII shared names in mount paths" setting is on (the default)
BOOL AFPCConvertNamesEnabled(void);

/// When convert is YES, Latin letters lose their accents and other scripts are transliterated via the system substring enumerator. When convert is NO, every non-ASCII character is replaced with an underscore. Either way, a usable mount point name is returned.
NSString *AFPCMountPointName(NSString *name, BOOL convert);

NS_ASSUME_NONNULL_END
