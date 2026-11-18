//
//  AFPFSAppleDoubleTests.m
//  AFPConnectTests
//
//  Created by Benjamin Lowry on 2026-11-11.
//

#import <XCTest/XCTest.h>

#import "AFPFSAppleDouble.h"

#import <libkern/OSByteOrder.h>

@interface AFPFSAppleDoubleTests : XCTestCase
@end

static NSData *finderInfo(const char *typeCreator)
{
    NSMutableData *fi = [NSMutableData dataWithLength:32];
    memcpy(fi.mutableBytes, typeCreator, 8);
    return fi;
}

static NSData *bytes(const char *s)
{
    return [NSData dataWithBytes:s length:strlen(s)];
}

@implementation AFPFSAppleDoubleTests

- (void)testEmptyHeader
{
    NSData *h = AFPFSDoubleHeader([NSMutableData dataWithLength:32], @[], @{}, 0, 0);
    XCTAssertEqual(h.length, (NSUInteger)AFPFSDoubleDefaultForkOffset);
    XCTAssertEqual(AFPFSDoubleHeaderLength(h), (uint64_t)AFPFSDoubleDefaultForkOffset);

    AFPFSDoubleContents *c = AFPFSParseDouble(h, h.length);
    XCTAssertNotNil(c);
    XCTAssertTrue(AFPFSFinderInfoIsEmpty(c.finderInfo));
    XCTAssertEqual(c.attributeNames.count, 0u);
    XCTAssertEqual(c.forkOffset, (uint64_t)AFPFSDoubleDefaultForkOffset);
    XCTAssertEqual(c.forkLength, 0u);
}

- (void)testRoundTrip
{
    NSArray *names = @[ @"com.example.one", @"com.example.two" ];
    NSDictionary *values = @{ names[0]: bytes("first value"), names[1]: bytes("2") };
    NSData *h = AFPFSDoubleHeader(finderInfo("APPLGRPH"), names, values, 1234, 0);

    AFPFSDoubleContents *c = AFPFSParseDouble(h, h.length + 1234);
    XCTAssertNotNil(c);
    XCTAssertEqualObjects(c.finderInfo, finderInfo("APPLGRPH"));
    XCTAssertEqualObjects(c.attributeNames, names);
    XCTAssertEqualObjects(c.attributes, values);
    XCTAssertEqual(c.forkOffset, (uint64_t)h.length);
    XCTAssertEqual(c.forkLength, 1234u);
}

- (void)testForkOffsetHint
{
    NSData *fi = [NSMutableData dataWithLength:32];
    XCTAssertEqual(AFPFSDoubleHeader(fi, @[], @{}, 0, 0x2000).length, 0x2000u);
    XCTAssertEqual(AFPFSDoubleHeader(fi, @[], @{}, 0, 0x100).length, (NSUInteger)AFPFSDoubleDefaultForkOffset);

    NSDictionary *big = @{ @"com.example.big": [NSMutableData dataWithLength:5000] };
    NSData *h = AFPFSDoubleHeader(fi, big.allKeys, big, 0, 0);
    XCTAssertEqual(h.length, 0x2000u);
    XCTAssertEqual(AFPFSDoubleHeader(fi, big.allKeys, big, 0, 0xEE2).length, 0x2000u);
    XCTAssertEqualObjects(AFPFSParseDouble(h, h.length).attributes, big);
}

- (void)testParsesWhatXnuWrites
{
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSURL *url = [bundle URLForResource:@"xnu-double" withExtension:@"bin"]
                 ?: [bundle URLForResource:@"xnu-double" withExtension:@"bin" subdirectory:@"fixtures"];
    NSData *file = url ? [NSData dataWithContentsOfURL:url] : nil;
    XCTAssertNotNil(file);

    XCTAssertEqual(AFPFSDoubleHeaderLength([file subdataWithRange:NSMakeRange(0, 0x32)]), 0xEE2u);
    AFPFSDoubleContents *c = AFPFSParseDouble([file subdataWithRange:NSMakeRange(0, 0xEE2)], file.length);
    XCTAssertNotNil(c);
    XCTAssertEqualObjects(c.finderInfo, finderInfo("TEXTttxt"));
    XCTAssertEqualObjects(c.attributeNames, (@[ @"com.example.one", @"com.example.two" ]));
    XCTAssertEqualObjects(c.attributes[@"com.example.one"], bytes("first value"));
    XCTAssertEqualObjects(c.attributes[@"com.example.two"], bytes("2"));
    XCTAssertEqual(c.forkOffset, 0xEE2u);
    XCTAssertEqual(c.forkLength, 300u);

    NSData *ours = AFPFSDoubleHeader(c.finderInfo, c.attributeNames, c.attributes, 300, 0);
    XCTAssertEqualObjects(ours, [file subdataWithRange:NSMakeRange(0, 0xEE2)]);
}

- (void)testRejectsDamage
{
    NSDictionary *values = @{ @"com.example.one": bytes("first value") };
    NSData *good = AFPFSDoubleHeader(finderInfo("TEXTttxt"), values.allKeys, values, 100, 0);

    NSMutableData *magic = [good mutableCopy];
    ((uint8_t *)magic.mutableBytes)[0] = 0xff;
    XCTAssertNil(AFPFSParseDouble(magic, magic.length + 100));
    XCTAssertEqual(AFPFSDoubleHeaderLength(magic), 0u);

    XCTAssertNil(AFPFSParseDouble(good, good.length + 99));

    NSMutableData *value = [good mutableCopy];
    uint8_t *entry = (uint8_t *)value.mutableBytes + 0x54 + 0x24;
    OSWriteBigInt32(entry, 4, 0x10000);
    XCTAssertNil(AFPFSParseDouble(value, value.length + 100));

    XCTAssertNil(AFPFSParseDouble([good subdataWithRange:NSMakeRange(0, 20)], 20));
}

- (void)testFinderInfoIsEmpty
{
    XCTAssertTrue(AFPFSFinderInfoIsEmpty([NSMutableData dataWithLength:32]));
    XCTAssertFalse(AFPFSFinderInfoIsEmpty(finderInfo("TEXTttxt")));
    NSMutableData *flags = [NSMutableData dataWithLength:32];
    ((uint8_t *)flags.mutableBytes)[8] = 0x40;
    XCTAssertFalse(AFPFSFinderInfoIsEmpty(flags));
}

@end
