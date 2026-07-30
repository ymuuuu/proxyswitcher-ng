#import <Foundation/Foundation.h>

// Parses a TLS ClientHello and returns the SNI host_name, or nil when the
// buffer is not a ClientHello, is truncated anywhere, or carries no SNI
// extension. Never reads past buf+len.
NSString *PSNSniffTLSServerName(const uint8_t *buf, size_t len);

// Parses an HTTP request head and returns the Host header value with any
// trailing ":port" removed, or nil when absent. Header-name match is
// case-insensitive. Never reads past buf+len.
NSString *PSNSniffHTTPHost(const uint8_t *buf, size_t len);
