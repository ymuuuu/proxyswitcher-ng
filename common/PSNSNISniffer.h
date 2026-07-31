#import <Foundation/Foundation.h>

// Parses a TLS ClientHello and returns the SNI host_name, or nil when the
// buffer is not a ClientHello, is truncated anywhere, or carries no SNI
// extension. Never reads past buf+len.
NSString *PSNSniffTLSServerName(const uint8_t *buf, size_t len);

// Parses an HTTP request head and returns the Host header value with any
// trailing ":port" removed, or nil when absent. Header-name match is
// case-insensitive. Never reads past buf+len.
NSString *PSNSniffHTTPHost(const uint8_t *buf, size_t len);

// YES when the string is safe to paste into an upstream request line: a DNS
// hostname, or a bracketed IPv6 literal. Both sniffers above apply this
// already; call it directly on any hostname that reached us by another route
// (a SOCKS5 domain address, for instance). A CR or LF would otherwise inject
// extra headers into a "CONNECT <host>:<port> HTTP/1.1\r\n" request.
BOOL PSNHostnameIsRequestLineSafe(NSString *host);
