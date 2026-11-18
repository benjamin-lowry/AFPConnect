//
//  AFPCEncoding.m
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//

#import "AFPCEncoding.h"
#import "AFPCInternal.h"

/// List of encodings the Mac OS X (pre-27) Connect to Server dialog offers for AFP 2 servers.
static const struct { const char *name; CFStringEncoding encoding; } kEncodings[] = {
    { "macroman", kCFStringEncodingMacRoman },
    { "macjapanese", kCFStringEncodingMacJapanese },
    { "macchinesetrad", kCFStringEncodingMacChineseTrad },
    { "macchinesesimp", kCFStringEncodingMacChineseSimp },
    { "mackorean", kCFStringEncodingMacKorean },
    { "macarabic", kCFStringEncodingMacArabic },
    { "machebrew", kCFStringEncodingMacHebrew },
    { "macgreek", kCFStringEncodingMacGreek },
    { "maccyrillic", kCFStringEncodingMacCyrillic },
    { "macukrainian", kCFStringEncodingMacUkrainian },
    { "maccentraleurope", kCFStringEncodingMacCentralEurRoman },
    { "maccroatian", kCFStringEncodingMacCroatian },
    { "macromanian", kCFStringEncodingMacRomanian },
    { "macturkish", kCFStringEncodingMacTurkish },
    { "macicelandic", kCFStringEncodingMacIcelandic },
    { "macthai", kCFStringEncodingMacThai },
    { "macfarsi", kCFStringEncodingMacFarsi },
};
static const size_t kEncodingCount = sizeof(kEncodings) / sizeof(kEncodings[0]);

// written before connecting, read by the converters afterwards
static CFStringEncoding currentEncoding = kCFStringEncodingMacRoman;
static size_t currentIndex = 0;

static int toUTF8(const char *src, int src_len, char *dest, int dest_len)
{
    CFStringRef s = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)src, src_len, currentEncoding, false);
    if (!s && currentEncoding != kCFStringEncodingMacRoman) {
        s = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)src, src_len, kCFStringEncodingMacRoman, false);
    }
    if (!s) {
        return -1;
    }
    CFMutableStringRef m = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, s);
    CFRelease(s);
    CFStringNormalize(m, kCFStringNormalizationFormC);
    Boolean ok = CFStringGetCString(m, dest, dest_len, kCFStringEncodingUTF8);
    CFRelease(m);
    return ok ? 0 : -1;
}

static int fromUTF8(const char *src, int src_len, char *dest, int dest_len)
{
    CFStringRef s = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)src, src_len, kCFStringEncodingUTF8, false);
    if (!s) {
        return -1;
    }
    CFIndex used = 0;
    CFRange all = CFRangeMake(0, CFStringGetLength(s));
    // loss byte of 0 so we strip out characters the encoding doesnt support
    CFIndex converted = CFStringGetBytes(s, all, currentEncoding, 0, false, (UInt8 *)dest, dest_len - 1, &used);
    CFRelease(s);
    if (converted != all.length) {
        return -1;
    }
    dest[used] = '\0';
    return 0;
}

@implementation AFPCEncoding

+ (NSArray<NSString *> *)names
{
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:kEncodingCount];
    for (size_t i = 0; i < kEncodingCount; i++) {
        [names addObject:@(kEncodings[i].name)];
    }
    return names;
}

static long indexOf(NSString *name)
{
    for (size_t i = 0; i < kEncodingCount; i++) {
        if ([name isEqualToString:@(kEncodings[i].name)]) {
            return (long)i;
        }
    }
    return -1;
}

+ (NSString *)displayNameFor:(NSString *)name
{
    long i = indexOf(name);
    if (i < 0) {
        return name;
    }
    return (__bridge NSString *)CFStringGetNameOfEncoding(kEncodings[i].encoding) ?: name;
}

+ (NSString *)defaultName
{
    CFStringEncoding system = CFStringGetSystemEncoding();
    for (size_t i = 0; i < kEncodingCount; i++) {
        if (kEncodings[i].encoding == system) {
            return @(kEncodings[i].name);
        }
    }
    return @"macroman";
}

+ (BOOL)useEncodingNamed:(NSString *)name
{
    long i = indexOf(name);
    if (i < 0) {
        return NO;
    }
    currentIndex = (size_t)i;
    currentEncoding = kEncodings[i].encoding;
    // use libafpclient's built-in macroman support and the converter otherwise
    if (currentEncoding == kCFStringEncodingMacRoman) {
        afp_set_longname_encoding(NULL, NULL);
    } else {
        afp_set_longname_encoding(toUTF8, fromUTF8);
    }
    return YES;
}

+ (NSStringEncoding)current
{
    return CFStringConvertEncodingToNSStringEncoding(currentEncoding);
}

+ (NSString *)currentName
{
    return @(kEncodings[currentIndex].name);
}

@end
