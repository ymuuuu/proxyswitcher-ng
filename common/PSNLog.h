#import <Foundation/Foundation.h>

// The log file the Settings "Logs" page reads. Root-owned, 0644.
NSString *PSNLogPath(void);

// Mirrors the `logging` preference. Off by default.
void PSNLogSetEnabled(BOOL enabled);

// Appends one timestamped line when logging is enabled. Thread-safe.
void PSNLogWrite(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// Always NSLog; additionally append to the file when logging is enabled.
#define PSLog(format, ...) \
    do { NSLog((format), ##__VA_ARGS__); PSNLogWrite((format), ##__VA_ARGS__); } while (0)
