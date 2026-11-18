//
//  AFPCNamesTests.m
//  AFPConnectTests
//
//  Created by Benjamin Lowry on 2026-11-11.
//

#import <XCTest/XCTest.h>

#import "AFPCNames.h"

@interface AFPCNamesTests : XCTestCase
@end

@implementation AFPCNamesTests

- (void)testASCIIUnchanged
{
    XCTAssertEqualObjects(AFPCMountPointName(@"Pumpkin's Public Folder", YES), @"Pumpkin's Public Folder");
    XCTAssertEqualObjects(AFPCMountPointName(@"Pumpkin's Public Folder", NO), @"Pumpkin's Public Folder");
}

- (void)testLatin
{
    XCTAssertEqualObjects(AFPCMountPointName(@"Pumpkin’s Shared Files", YES), @"Pumpkin's Shared Files");
    XCTAssertEqualObjects(AFPCMountPointName(@"Pokémon", YES), @"Pokemon");
    XCTAssertEqualObjects(AFPCMountPointName(@"Ich heiße", YES), @"Ich heisse");
    XCTAssertEqualObjects(AFPCMountPointName(@"Pumpkin’s Shared Files", NO), @"Pumpkin_s Shared Files");
    XCTAssertEqualObjects(AFPCMountPointName(@"Pokémon", NO), @"Pok_mon");
}

- (void)testVietnamese
{
    NSString *composed = @"các tệp của tôi".precomposedStringWithCanonicalMapping;
    NSString *decomposed = composed.decomposedStringWithCanonicalMapping;
    XCTAssertEqualObjects(AFPCMountPointName(composed, YES), @"cac tep cua toi");
    XCTAssertEqualObjects(AFPCMountPointName(decomposed, YES), @"cac tep cua toi");
    // one _ per letter however it's encoded
    XCTAssertEqualObjects(AFPCMountPointName(composed, NO), @"c_c t_p c_a t_i");
    XCTAssertEqualObjects(AFPCMountPointName(decomposed, NO), @"c_c t_p c_a t_i");
    XCTAssertEqualObjects(AFPCMountPointName(@"Đà Nẵng", YES), @"Da Nang");
}

- (void)testJapanese
{
    XCTAssertEqualObjects(AFPCMountPointName(@"私のMac", YES), @"watakushi no Mac");
    XCTAssertEqualObjects(AFPCMountPointName(@"東京の写真", YES), @"toukyou no shashin");
    XCTAssertEqualObjects(AFPCMountPointName(@"私のMac", NO), @"__Mac");
}

- (void)testOtherScripts
{
    XCTAssertEqualObjects(AFPCMountPointName(@"君子", YES), @"kunshi");
    NSString *korean = AFPCMountPointName(@"한글 텍스트", YES);
    XCTAssertTrue([korean canBeConvertedToEncoding:NSASCIIStringEncoding] && [korean containsString:@" "], @"%@", korean);
}

- (void)testUnusable
{
    XCTAssertEqualObjects(AFPCMountPointName(@"📁 Stuff", YES), @"_ Stuff");
    XCTAssertEqualObjects(AFPCMountPointName(@"👩‍👩‍👧 Stuff", NO), @"_ Stuff");
    XCTAssertEqualObjects(AFPCMountPointName(@"a/b", YES), @"a_b");
    XCTAssertEqualObjects(AFPCMountPointName(@"..", YES), @"AFP Share");
    XCTAssertEqualObjects(AFPCMountPointName(@"  ", NO), @"AFP Share");
}

@end
