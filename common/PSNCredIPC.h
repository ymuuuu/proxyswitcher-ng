#import <Foundation/Foundation.h>

// UNIX-domain socket the daemon listens on for credential set/get/delete.
// Preferences.app (mobile) connects here; each message is a length-prefixed
// (4-byte big-endian length + binary-plist payload) request/reply dictionary.
// Chosen over XPC because the theos iOS SDK ships no <xpc/xpc.h> and the NSXPC
// mach-service initializers are API_UNAVAILABLE(ios); POSIX sockets build on
// the same SDK. The password is handed over in memory, never written to disk.
#define kPSNCredSocketPath "/var/tmp/proxyswitcherngd.creds.sock"

// Read one framed message. Returns nil on EOF, timeout, error, or oversize.
NSData *PSNCredFrameRead(int fd);

// Write one framed message. NO on error.
BOOL PSNCredFrameWrite(int fd, NSData *payload);
