//
//  Logger.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/10/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Logger.h"

static LogLevel LoggerLogLevel = LOG_I;

os_log_t MoonlightPublicLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.moonlight-stream.Moonlight", "app");
    });
    return log;
}

void LogTagv(LogLevel level, NSString* tag, NSString* fmt, va_list args);

void Log(LogLevel level, NSString* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogTagv(level, NULL, fmt, args);
    va_end(args);
}

void LogTag(LogLevel level, NSString* tag, NSString* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogTagv(level, tag, fmt, args);
    va_end(args);
}

void LogTagv(LogLevel level, NSString* tag, NSString* fmt, va_list args) {
    NSString* levelPrefix = @"";
    
    if (level < LoggerLogLevel) {
        return;
    }
    
    switch(level) {
        case LOG_D:
            levelPrefix = PRFX_DEBUG;
            break;
        case LOG_I:
            levelPrefix = PRFX_INFO;
            break;
        case LOG_W:
            levelPrefix = PRFX_WARN;
            break;
        case LOG_E:
            levelPrefix = PRFX_ERROR;
            break;
        default:
            levelPrefix = @"";
            assert(false);
            break;
    }
    NSString* prefixedString;
    if (tag) {
        prefixedString = [NSString stringWithFormat:@"%@ (%@) %@", levelPrefix, tag, fmt];
    } else {
        prefixedString = [NSString stringWithFormat:@"%@ %@", levelPrefix, fmt];
    }

    va_list args_copy;
    va_copy(args_copy, args);
    vfprintf(stderr, [prefixedString stringByAppendingString:@"\n"].UTF8String, args_copy);
    va_end(args_copy);

    va_list args_copy2;
    va_copy(args_copy2, args);
    NSString* formatted = [[NSString alloc] initWithFormat:prefixedString arguments:args_copy2];
    va_end(args_copy2);

    // Emit with explicit public visibility so the message is not redacted
    // as <private> when captured from a non-debugger device log stream.
    os_log(MoonlightPublicLog(), "%{public}s", formatted.UTF8String);

    NSLog(@"%@", formatted);
}
