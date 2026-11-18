//
//  AFPCEncodingTests.m
//  AFPConnectTests
//
//  Created by Benjamin Lowry on 2026-11-11.
//

#import <XCTest/XCTest.h>

#import "AFPCEncoding.h"
#import "AFPCInternal.h"

@interface AFPCEncodingTests : XCTestCase
@end

@implementation AFPCEncodingTests

- (void)tearDown
{
    [AFPCEncoding useEncodingNamed:@"macroman"];
}

static NSData *toAFP(NSString *path)
{
    char out[512];
    if (convert_path_to_afp(kFPLongName, out, path.UTF8String, sizeof(out)) != 0) {
        return nil;
    }
    return [NSData dataWithBytes:out length:strlen(out)];
}

static NSString *toUnix(NSData *name)
{
    char in[256] = { 0 }, out[512];
    memcpy(in, name.bytes, MIN(name.length, sizeof(in) - 1));
    if (convert_path_to_unix(kFPLongName, out, in, sizeof(out)) != 0) {
        return nil;
    }
    return @(out);
}

- (void)testNames
{
    XCTAssertEqualObjects(AFPCEncoding.names.firstObject, @"macroman");
    XCTAssertTrue([AFPCEncoding.names containsObject:AFPCEncoding.defaultName]);
    XCTAssertEqualObjects([AFPCEncoding displayNameFor:@"macjapanese"], @"Japanese (Mac OS)");
    XCTAssertFalse([AFPCEncoding useEncodingNamed:@"ebcdic"]);
}

- (void)testMacRomanByDefault
{
    XCTAssertTrue([AFPCEncoding useEncodingNamed:@"macroman"]);
    XCTAssertEqualObjects(toAFP(@"Pokémon"), [NSData dataWithBytes:"Pok\x8emon" length:7]);
    XCTAssertEqual(AFPCEncoding.current, NSMacOSRomanStringEncoding);
}

- (void)testJapanese
{
    XCTAssertTrue([AFPCEncoding useEncodingNamed:@"macjapanese"]);
    NSData *bytes = toAFP(@"日本語");
    XCTAssertEqualObjects(bytes, [NSData dataWithBytes:"\x93\xfa\x96\x7b\x8c\xea" length:6]);
    XCTAssertEqualObjects(toUnix(bytes), @"日本語");
    XCTAssertNil(toAFP(@"😀"));
    XCTAssertEqualObjects(toAFP(@"ReadMe"), [NSData dataWithBytes:"ReadMe" length:6]);
}

- (void)testCyrillicAndPrecomposition
{
    XCTAssertTrue([AFPCEncoding useEncodingNamed:@"maccyrillic"]);
    NSData *bytes = toAFP(@"Музыка");
    XCTAssertEqual(bytes.length, 6u);
    XCTAssertEqualObjects(toUnix(bytes), @"Музыка");
    // й should return as precomposed form
    XCTAssertEqualObjects(toUnix(toAFP(@"й".decomposedStringWithCanonicalMapping.precomposedStringWithCanonicalMapping)), @"й");
}

@end
