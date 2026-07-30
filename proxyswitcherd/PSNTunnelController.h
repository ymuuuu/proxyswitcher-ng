#import <Foundation/Foundation.h>

// Posted on the Darwin center when the controller fails open (tunnel torn
// down, cooperative mode should be re-applied) and when it recovers (tunnel
// re-engaged; system proxy keys should be cleared again).
#define PSNTunnelStateChangedNotification "io.ymuu.proxyswitcherng/tunnelstatechanged"

@interface PSNTunnelController : NSObject

+ (instancetype)sharedInstance;

// running: routes are installed and the engine is up.
// suspended: tunnel was wanted but failed (start failure or health-check
// fail-open); cooperative mode is in effect and the controller retries on
// its own every kProbeInterval.
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) BOOL suspended;

// Brings up tunnel mode. Idempotent when upstream AND physical gateway are
// unchanged (applyFromPreferences re-runs on network_change, and a moved
// gateway invalidates the /32 exclusions). On failure: tears everything down,
// enters suspended (auto-retry armed), returns NO - the caller then applies
// cooperative mode.
- (BOOL)startWithUpstreamHost:(NSString *)host
                         port:(int)port
                     username:(NSString *)user
                     password:(NSString *)pass;

// Full teardown and back to a clean stopped state. Safe to call anytime.
- (void)stop;

// Called on user-initiated re-applies (settingschanged): drops a suspension
// so the next start attempt happens now instead of at the next probe tick.
- (void)clearSuspension;

@end
