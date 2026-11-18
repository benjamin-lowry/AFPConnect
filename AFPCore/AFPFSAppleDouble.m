//
//  AFPFSAppleDouble.m
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import "AFPFSAppleDouble.h"

#import <libkern/OSByteOrder.h>

enum {
    kMagic = 0x00051607,
    kVersion = 0x00020000,
    kEntryFinderInfo = 9,
    kEntryResourceFork = 2,
    kFinderInfoOffset = 0x32,
    kFinderInfoSize = 32,
    kAttrHeaderOffset = 0x54, // FinderInfo plus 2 bytes padding
    kAttrHeaderSize = 0x24,
    kAttrMagic = 0x41545452,  // 'ATTR'
    kAttrEntryFixed = 11,     // offset, length, flags, name length
};

static uint64_t align4(uint64_t x)
{
    return (x + 3) & ~(uint64_t)3;
}

@implementation AFPFSDoubleContents
@end

BOOL AFPFSFinderInfoIsEmpty(NSData *finderInfo)
{
    const uint8_t *p = finderInfo.bytes;
    for (NSUInteger i = 0; i < finderInfo.length; i++) {
        if (p[i]) {
            return NO;
        }
    }
    return YES;
}

NSData *AFPFSDoubleHeader(NSData *finderInfo, NSArray<NSString *> *names,
                          NSDictionary<NSString *, NSData *> *attributes, uint64_t forkLength,
                          uint64_t minForkOffset)
{
    // Entry name length is one byte, so names longer than 2^8 cannot be described
    names = [names filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
        return strlen(name.UTF8String) + 1 <= UINT8_MAX && attributes[name] != nil;
    }]];
    // Entries first, then values
    uint64_t entriesEnd = kAttrHeaderOffset + kAttrHeaderSize;
    for (NSString *name in names) {
        entriesEnd += align4(kAttrEntryFixed + strlen(name.UTF8String) + 1);
    }
    uint64_t dataLength = 0;
    for (NSString *name in names) {
        dataLength += attributes[name].length;
    }
    uint64_t dataEnd = entriesEnd + dataLength;
    // Room to spare between dataEnd and forkOffset, grow in 4kb steps past that.
    uint64_t forkOffset;
    if (minForkOffset >= dataEnd && minForkOffset >= AFPFSDoubleDefaultForkOffset) {
        forkOffset = minForkOffset;
    } else if (dataEnd <= AFPFSDoubleDefaultForkOffset) {
        forkOffset = AFPFSDoubleDefaultForkOffset;
    } else {
        forkOffset = (dataEnd + 4095) & ~(uint64_t)4095;
    }

    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)forkOffset];
    uint8_t *p = d.mutableBytes;
    OSWriteBigInt32(p, 0, kMagic);
    OSWriteBigInt32(p, 4, kVersion);
    memcpy(p + 8, "Mac OS X        ", 16);
    OSWriteBigInt16(p, 24, 2);
    OSWriteBigInt32(p, 26, kEntryFinderInfo);
    OSWriteBigInt32(p, 30, kFinderInfoOffset);
    OSWriteBigInt32(p, 34, (uint32_t)(forkOffset - kFinderInfoOffset));
    OSWriteBigInt32(p, 38, kEntryResourceFork);
    OSWriteBigInt32(p, 42, (uint32_t)forkOffset);
    OSWriteBigInt32(p, 46, (uint32_t)forkLength);
    if (finderInfo.length == kFinderInfoSize) {
        memcpy(p + kFinderInfoOffset, finderInfo.bytes, kFinderInfoSize);
    }

    uint8_t *h = p + kAttrHeaderOffset;
    OSWriteBigInt32(h, 0, kAttrMagic);
    OSWriteBigInt32(h, 8, (uint32_t)forkOffset);  // total size
    OSWriteBigInt32(h, 12, (uint32_t)entriesEnd); // data start
    OSWriteBigInt32(h, 16, (uint32_t)dataLength);
    OSWriteBigInt16(h, 34, (uint16_t)names.count);

    uint64_t entry = kAttrHeaderOffset + kAttrHeaderSize;
    uint64_t value = entriesEnd;
    for (NSString *name in names) {
        NSData *v = attributes[name];
        const char *n = name.UTF8String;
        size_t nameLength = strlen(n) + 1;
        OSWriteBigInt32(p, entry, (uint32_t)value);
        OSWriteBigInt32(p, entry + 4, (uint32_t)v.length);
        p[entry + 10] = (uint8_t)nameLength;
        memcpy(p + entry + kAttrEntryFixed, n, nameLength);
        memcpy(p + value, v.bytes, v.length);
        entry += align4(kAttrEntryFixed + nameLength);
        value += v.length;
    }
    return d;
}

uint64_t AFPFSDoubleHeaderLength(NSData *start)
{
    if (start.length < kFinderInfoOffset) {
        return 0;
    }
    const uint8_t *p = start.bytes;
    if (OSReadBigInt32(p, 0) != kMagic) {
        return 0;
    }
    uint16_t count = OSReadBigInt16(p, 24);
    if ((uint64_t)26 + (uint64_t)count * 12 > kFinderInfoOffset) {
        return 0;
    }
    // header runs until resource fork, or past the last entry without one
    uint64_t end = 0;
    for (uint16_t i = 0; i < count; i++) {
        uint32_t id = OSReadBigInt32(p, 26 + i * 12);
        uint64_t offset = OSReadBigInt32(p, 30 + i * 12);
        uint64_t length = OSReadBigInt32(p, 34 + i * 12);
        if (id == kEntryResourceFork) {
            return offset;
        }
        end = MAX(end, offset + length);
    }
    return end;
}

AFPFSDoubleContents *AFPFSParseDouble(NSData *header, uint64_t fileLength)
{
    const uint8_t *p = header.bytes;
    uint64_t len = header.length;
    if (len < kFinderInfoOffset || OSReadBigInt32(p, 0) != kMagic || OSReadBigInt32(p, 4) != kVersion) {
        return nil;
    }
    uint16_t count = OSReadBigInt16(p, 24);
    if ((uint64_t)26 + (uint64_t)count * 12 > len) {
        return nil;
    }

    AFPFSDoubleContents *c = [[AFPFSDoubleContents alloc] init];
    c.finderInfo = [NSMutableData dataWithLength:kFinderInfoSize];
    c.attributeNames = @[];
    c.attributes = @{};
    c.forkOffset = fileLength;
    c.forkLength = 0;
    uint64_t fiOffset = 0, fiLength = 0;

    for (uint16_t i = 0; i < count; i++) {
        uint32_t id = OSReadBigInt32(p, 26 + i * 12);
        uint64_t offset = OSReadBigInt32(p, 30 + i * 12);
        uint64_t length = OSReadBigInt32(p, 34 + i * 12);
        if (id == kEntryFinderInfo) {
            if (offset + MIN(length, (uint64_t)kFinderInfoSize) > len) {
                return nil;
            }
            fiOffset = offset;
            fiLength = length;
            c.finderInfo = [NSData dataWithBytes:p + offset length:(NSUInteger)MIN(length, (uint64_t)kFinderInfoSize)];
            if (c.finderInfo.length < kFinderInfoSize) {
                NSMutableData *fi = [c.finderInfo mutableCopy];
                fi.length = kFinderInfoSize;
                c.finderInfo = fi;
            }
        } else if (id == kEntryResourceFork) {
            if (offset + length > fileLength) {
                return nil;
            }
            c.forkOffset = offset;
            c.forkLength = length;
        }
    }

    // xattrs are stored in an ATTR header after the FinderInfo inside its entry
    uint64_t attrStart = fiOffset + kFinderInfoSize + 2;
    if (fiLength >= kFinderInfoSize + 2 + kAttrHeaderSize && attrStart + kAttrHeaderSize <= len
            && OSReadBigInt32(p, attrStart) == kAttrMagic) {
        uint16_t numAttrs = OSReadBigInt16(p, attrStart + 34);
        uint64_t entry = attrStart + kAttrHeaderSize;
        uint64_t limit = MIN(len, fiOffset + fiLength);
        NSMutableArray *names = [NSMutableArray arrayWithCapacity:numAttrs];
        NSMutableDictionary *values = [NSMutableDictionary dictionaryWithCapacity:numAttrs];
        for (uint16_t i = 0; i < numAttrs; i++) {
            if (entry + kAttrEntryFixed > limit) {
                return nil;
            }
            uint64_t offset = OSReadBigInt32(p, entry);
            uint64_t length = OSReadBigInt32(p, entry + 4);
            uint8_t nameLength = p[entry + 10];
            if (!nameLength || entry + kAttrEntryFixed + nameLength > limit || offset + length > limit) {
                return nil;
            }
            NSString *name = [[NSString alloc] initWithBytes:p + entry + kAttrEntryFixed
                                                      length:nameLength - 1
                                                    encoding:NSUTF8StringEncoding];
            if (!name) {
                return nil;
            }
            [names addObject:name];
            values[name] = [NSData dataWithBytes:p + offset length:(NSUInteger)length];
            entry += align4(kAttrEntryFixed + nameLength);
        }
        c.attributeNames = names;
        c.attributes = values;
    }
    return c;
}
