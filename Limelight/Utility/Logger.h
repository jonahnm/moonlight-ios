//
//  Logger.h
//  Moonlight
//
//  Created by Diego Waxemberg on 2/10/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#ifndef Limelight_Logger_h
#define Limelight_Logger_h

#import <stdarg.h>
#import <os/log.h>

typedef enum {
    LOG_D,
    LOG_I,
    LOG_W,
    LOG_E
} LogLevel;

#define PRFX_DEBUG @"<DEBUG>"
#define PRFX_INFO @"<INFO>"
#define PRFX_WARN @"<WARN>"
#define PRFX_ERROR @"<ERROR>"

void Log(LogLevel level, NSString* fmt, ...);
void LogTag(LogLevel level, NSString* tag, NSString* fmt, ...);

// Shared os_log handle whose messages are emitted with explicit public
// visibility. Use this for diagnostics that must survive iOS privacy
// redaction (<private>) when captured via idevicesyslog / log collect.
os_log_t MoonlightPublicLog(void);

#endif
