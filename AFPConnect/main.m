//
//  main.m
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-05.
//

#import <Cocoa/Cocoa.h>

#import "ACCommandLine.h"

int main(int argc, const char * argv[]) {
    // if we have a CLI argument, don't run the gui
    if (ACIsCommandLine(argc, argv)) {
        @autoreleasepool {
            return ACRunCommandLine(argc, argv);
        }
    } else {
        return NSApplicationMain(argc, argv);
    }
}
