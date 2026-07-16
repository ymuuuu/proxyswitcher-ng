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
@end
