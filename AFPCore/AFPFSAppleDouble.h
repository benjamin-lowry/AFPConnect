//
//  AFPFSAppleDouble.h
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Offset at which xnu puts the resource fork in an AppleDouble file it creates
enum { AFPFSDoubleDefaultForkOffset = 0xEE2 };

@interface AFPFSDoubleContents : NSObject
@property (copy) NSData *finderInfo; // 32 bytes
@property (copy) NSArray<NSString *> *attributeNames; // in file order.
@property (copy) NSDictionary<NSString *, NSData *> *attributes;
@property uint64_t forkOffset;
@property uint64_t forkLength;
@end

/// Returns a header (everything before the fork) for this FinderInfo, xattrs, and fork length, in the same layout xnu creates
NSData *AFPFSDoubleHeader(NSData *finderInfo, NSArray<NSString *> *names,
                          NSDictionary<NSString *, NSData *> *attributes, uint64_t forkLength,
                          uint64_t minForkOffset);

/// Parses an AppleDouble header. fileLength bounds the fork. Returns nil if it isn't an xnu-generated AppleDouble file
AFPFSDoubleContents *_Nullable AFPFSParseDouble(NSData *header, uint64_t fileLength);

/// How much of an AppleDouble to read to parse the header
uint64_t AFPFSDoubleHeaderLength(NSData *start);

BOOL AFPFSFinderInfoIsEmpty(NSData *finderInfo);

NS_ASSUME_NONNULL_END
