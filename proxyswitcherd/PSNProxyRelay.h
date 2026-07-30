#import <Foundation/Foundation.h>

extern const int kPSNRelayPort; // 8899

@interface PSNProxyRelay : NSObject
+ (instancetype)sharedInstance;
- (void)startIfNeeded; // idempotent: binds 127.0.0.1:kPSNRelayPort, spawns accept loop
// Set the single active upstream. user==nil/empty => relay refuses (auth-only path).
- (void)configureUpstreamHost:(NSString *)host port:(int)port
                         socks:(BOOL)socks
                      username:(NSString *)user password:(NSString *)pass;
- (void)clearUpstream; // no active auth config; relay closes new conns

// Tunnel mode: serve the tun2socks engine (SOCKS5 in, HTTP CONNECT out, SNI/Host
// hostname recovery). Unlike -configureUpstreamHost:..., this does NOT require
// credentials - the relay serves every client while a tunnel upstream is set.
// 'address' MUST be a numeric IP: it is dialled after the tunnel routes exist,
// so a hostname would mean DNS inside the tunnel. The controller resolves and
// excludes it before takeover.
- (void)configureTunnelUpstreamAddress:(NSString *)address
                                  port:(int)port
                              username:(NSString *)user
                              password:(NSString *)pass;
- (void)clearTunnelUpstream;
@end
