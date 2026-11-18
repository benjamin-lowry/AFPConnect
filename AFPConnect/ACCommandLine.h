//
//  ACCommandLine.h
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-05.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns YES when argv indicates a command-line (rather than GUI) run.
BOOL ACIsCommandLine(int argc, const char *_Nonnull argv[_Nonnull]);

/// Runs the command-line and returns the exit status.
int ACRunCommandLine(int argc, const char *_Nonnull argv[_Nonnull]);

NS_ASSUME_NONNULL_END
