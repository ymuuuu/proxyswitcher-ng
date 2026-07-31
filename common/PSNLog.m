#import "PSNLog.h"

static NSString * const kPSNLogFilePath = @"/var/mobile/Library/Logs/ProxySwitcherNG.log";
static NSLock *gPSNLogLock;
static BOOL gPSNLogEnabled;

static void PSNLogInitLockIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gPSNLogLock = [NSLock new]; });
}

NSString *PSNLogPath(void) { return kPSNLogFilePath; }

void PSNLogSetEnabled(BOOL enabled) {
    PSNLogInitLockIfNeeded();
    [gPSNLogLock lock];
    gPSNLogEnabled = enabled;
    [gPSNLogLock unlock];
}

// Built once per process. NSDateFormatter is expensive to construct and is not
// thread-safe, so it is only ever touched from PSNLogAppendLineLocked, which
// runs under gPSNLogLock. Consequence: the timestamp offset is resolved at
// first use, so a device time-zone change is not picked up until the daemon
// restarts (KeepAlive makes that routine).
static NSDateFormatter *PSNLogFormatter(void) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZZZZZ"];
    });
    return fmt;
}

static void PSNLogAppendLineLocked(NSString *line) {
    if (line.length == 0) { return; }

    NSString *entry = [NSString stringWithFormat:@"%@ %@\n",
                       [PSNLogFormatter() stringFromDate:[NSDate date]], line];

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kPSNLogFilePath];
    if (handle) {
        [handle seekToEndOfFile];
        [handle writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
        return;
    }

    // No file yet. Create the directory, then the file, and set the mode once:
    // writeToFile:atomically: renames a temp file into place, so the result
    // carries umask permissions and the Settings "Logs" page (running as
    // mobile) could not read it. Appends cannot change the mode, so doing this
    // on the create path only is enough.
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [kPSNLogFilePath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if ([entry writeToFile:kPSNLogFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        [fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:kPSNLogFilePath error:nil];
    }
}

void PSNLogWrite(NSString *format, ...) {
    PSNLogInitLockIfNeeded();

    // Read the flag before formatting. Logging is off by default and PSLog sits
    // on the relay's per-connection paths, so formatting first would allocate a
    // string per call only to discard it.
    [gPSNLogLock lock];
    BOOL enabled = gPSNLogEnabled;
    [gPSNLogLock unlock];
    if (!enabled) { return; }

    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    [gPSNLogLock lock];
    PSNLogAppendLineLocked(line);
    [gPSNLogLock unlock];
}
