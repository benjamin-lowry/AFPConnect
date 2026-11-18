//
//  AFPCNames.m
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-08.
//

#import "AFPCNames.h"
#import "AFPCDefaults.h"

NSString *const AFPCConvertNamesKey = @"ConvertNonASCIINames";

BOOL AFPCConvertNamesEnabled(void)
{
    id value = [AFPCSharedDefaults() objectForKey:AFPCConvertNamesKey];
    return value ? [value boolValue] : YES;
}

static BOOL isASCII(NSString *s)
{
    return [s canBeConvertedToEncoding:NSASCIIStringEncoding];
}

static NSString *latinASCII(NSString *s)
{
    return [s stringByApplyingTransform:@"Latin-ASCII" reverse:NO] ?: s;
}

// Words in Latin script keep their spelling. others are transliterated to latin by the system based on whatever language the entire name is identified as
static NSString *transliterate(NSString *name)
{
    CFRange all = CFRangeMake(0, (CFIndex)name.length);
    NSString *language = CFBridgingRelease(CFStringTokenizerCopyBestStringLanguage((__bridge CFStringRef)name, all));
    CFLocaleRef locale = CFLocaleCreate(kCFAllocatorDefault, (__bridge CFStringRef)(language ?: @"en"));
    CFStringTokenizerRef tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault, (__bridge CFStringRef)name, all,
                                                             kCFStringTokenizerUnitWord, locale);
    NSMutableString *out = [NSMutableString string];
    NSUInteger last = 0;
    BOOL lastTranscribed = NO;
    while (CFStringTokenizerAdvanceToNextToken(tokenizer) != kCFStringTokenizerTokenNone) {
        CFRange r = CFStringTokenizerGetCurrentTokenRange(tokenizer);
        NSRange range = NSMakeRange((NSUInteger)r.location, (NSUInteger)r.length);
        NSString *word = [name substringWithRange:range];
        NSString *latin = nil;
        if (!isASCII(latinASCII(word))) {
            latin = CFBridgingRelease(CFStringTokenizerCopyCurrentTokenAttribute(tokenizer,
                                                                                kCFStringTokenizerAttributeLatinTranscription));
        }
        if (range.location > last) {
            [out appendString:[name substringWithRange:NSMakeRange(last, range.location - last)]];
        } else if (out.length && (latin || lastTranscribed)) {
            // cjk strings e.g. 私のMac have no spaces between words but the latin spelling needs them
            [out appendString:@" "];
        }
        [out appendString:latin ?: word];
        lastTranscribed = latin != nil;
        last = NSMaxRange(range);
    }
    if (last < name.length) {
        [out appendString:[name substringFromIndex:last]];
    }
    CFRelease(tokenizer);
    CFRelease(locale);
    return latinASCII(out);
}

NSString *AFPCMountPointName(NSString *name, BOOL convert)
{
    NSString *text = name.precomposedStringWithCanonicalMapping;
    if (convert && !isASCII(text)) {
        text = transliterate(text);
    }
    // anything still outside ascii (e.g. emoji) gets one underscore per character
    NSMutableString *safe = [NSMutableString stringWithCapacity:text.length];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *c, NSRange r, NSRange e, BOOL *stop) {
        unichar first = [c characterAtIndex:0];
        BOOL ok = c.length == 1 && first >= 0x20 && first < 0x7f && first != '/';
        [safe appendString:ok ? c : @"_"];
    }];
    NSString *trimmed = [safe stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!trimmed.length || [trimmed isEqualToString:@"."] || [trimmed isEqualToString:@".."]) {
        // fallback so we never return an empty mount point.
        // it's fine if this conflicts with an existing mount since fskit automatically
        // deduplicates mount points
        return @"AFP Share";
    }
    return trimmed;
}
