#import "PSNTunnelController.h"
#import "PSNTunnelDevice.h"
#import "PSNTunnelNet.h"
#import "PSNProxyRelay.h"
#import "PSNSocketUtil.h"
#import "PSNLog.h"

#import <netdb.h>
#import <net/if.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

// SCDynamicStore is marked API_UNAVAILABLE(ios) in the SDK headers, but the
// symbols exist on-device (SystemConfiguration/configd exports them and system
// daemons use them). Declared locally — the same workaround SCNetworkHeader.h
// uses for the SCPreferences API. callout/context are void* because this file
// only ever passes NULL for them.
typedef const struct __SCDynamicStore *SCDynamicStoreRef;
extern SCDynamicStoreRef SCDynamicStoreCreate(CFAllocatorRef allocator, CFStringRef name, void *callout, void *context);
extern CFPropertyListRef SCDynamicStoreCopyValue(SCDynamicStoreRef store, CFStringRef key);

// The vendored engine's public API (src/hev-main.h; on ADDITIONAL_OBJCFLAGS' -I list).
#include "hev-main.h"

static NSString * const kEngineConfigPath = @"/var/tmp/psn-tunnel.yml";
static const NSTimeInterval kProbeInterval   = 10.0;  // health/retry cadence
static const NSTimeInterval kProbeTimeout    = 4.0;
static const int            kProbeMaxFails   = 2;     // consecutive fails before fail-open
static const NSTimeInterval kEngineSettleSec = 0.25;  // startup sanity window

typedef NS_ENUM(NSInteger, PSNTunnelState) {
    PSNTunnelStateStopped,
    PSNTunnelStateRunning,
    PSNTunnelStateSuspended,   // wanted but down; retry armed; cooperative in effect
};

@implementation PSNTunnelController {
    dispatch_queue_t _stateQ;
    PSNTunnelState _state;
    PSNTunnelDevice *_device;
    NSThread *_engineThread;
    dispatch_source_t _probeTimer;
    int _consecFails;
    // Stored upstream (kept while suspended so retry needs no caller).
    NSString *_upHost; int _upPort; NSString *_upUser; NSString *_upPass;
    NSString *_upIp;                          // resolved BEFORE any route exists
    NSString *_physGw; unsigned _physIdx;     // physical default route at start time
}

+ (instancetype)sharedInstance {
    static PSNTunnelController *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PSNTunnelController new]; });
    return s;
}

// Identity marker for "am I already on _stateQ?". The address is the value;
// only its uniqueness matters.
static const void * const kPSNTunnelStateQKey = &kPSNTunnelStateQKey;

- (instancetype)init {
    if ((self = [super init])) {
        _stateQ = dispatch_queue_create("io.ymuu.proxyswitcherngd.tunnel", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_stateQ, kPSNTunnelStateQKey,
                                    (void *)kPSNTunnelStateQKey, NULL);
        _state = PSNTunnelStateStopped;
    }
    return self;
}

// Reads _state from ANY thread, including _stateQ itself. A bare
// dispatch_sync onto the queue you are already running on deadlocks
// instantly, and these are public getters - the health-probe block, a future
// helper on _stateQ, or a caller that only knows the public API can all reach
// them. The queue-specific check makes that reentrancy safe instead of fatal.
- (BOOL)stateIs:(PSNTunnelState)want {
    if (dispatch_get_specific(kPSNTunnelStateQKey) == kPSNTunnelStateQKey) {
        return (_state == want);
    }
    __block BOOL v = NO;
    dispatch_sync(_stateQ, ^{ v = (_state == want); });
    return v;
}

- (BOOL)running   { return [self stateIs:PSNTunnelStateRunning]; }
- (BOOL)suspended { return [self stateIs:PSNTunnelStateSuspended]; }

static void PSNTunnelPostStateChanged(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(PSNTunnelStateChangedNotification), NULL, NULL, true);
}

#pragma mark - helpers (always on _stateQ)

- (NSString *)resolveHostToIPv4:(NSString *)host {
    struct in_addr probe;
    if (inet_pton(AF_INET, host.UTF8String, &probe) == 1) { return host; }

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host.UTF8String, NULL, &hints, &res) != 0 || !res) {
        PSLog(@"[tunnel] cannot resolve upstream %@", host);
        return nil;
    }
    char a[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, a, sizeof(a));
    freeaddrinfo(res);
    return [NSString stringWithUTF8String:a];
}

// The current IPv4 DNS resolvers, read BEFORE the takeover. Public API, no
// entitlement needed.
- (NSArray<NSString *> *)currentIPv4Resolvers {
    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("proxyswitcherngd"), NULL, NULL);
    if (!store) { return @[]; }
    CFPropertyListRef v = SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/DNS"));
    CFRelease(store);
    NSArray *addrs = [(__bridge_transfer NSDictionary *)v objectForKey:@"ServerAddresses"];
    NSMutableArray *out = [NSMutableArray new];
    for (id a in addrs ?: @[]) {
        if (![a isKindOfClass:[NSString class]]) { continue; }
        struct in_addr chk;
        if (inet_pton(AF_INET, [(NSString *)a UTF8String], &chk) == 1 && chk.s_addr != 0) {
            [out addObject:a];
        }
    }
    return out;
}

// Engine config: upstream's published iOS low-memory preset (task stack must
// hold the TCP buffer: 24576 = 20480 + 4096). tunnel.mtu must equal the
// interface MTU set in Task 6 - with an external fd the engine uses mtu only
// as its read size (verified in hev-socks5-tunnel.c tunnel_init).
// udp:'udp' makes the engine attempt UDP ASSOCIATE; the Task-7 bridge refuses
// it with 0x07, which is the deliberate QUIC/UDP blackhole.
- (BOOL)writeEngineConfig {
    NSString *yaml = [NSString stringWithFormat:
        @"tunnel:\n"
        @"  mtu: %u\n"
        @"socks5:\n"
        @"  address: '127.0.0.1'\n"
        @"  port: %d\n"
        @"  udp: 'udp'\n"
        @"misc:\n"
        @"  task-stack-size: 24576\n"
        @"  tcp-buffer-size: 4096\n"
        @"  max-session-count: 1200\n"
        @"  log-level: warn\n",
        kPSNTunMTU, kPSNRelayPort];
    NSError *err = nil;
    if (![yaml writeToFile:kEngineConfigPath atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        PSLog(@"[tunnel] cannot write %@: %@", kEngineConfigPath, err.localizedDescription);
        return NO;
    }
    return YES;
}

- (void)engineThreadMain {
    @autoreleasepool {
        PSLog(@"[tunnel] engine starting on fd %d", _device.fd);
        int rc = hev_socks5_tunnel_main(kEngineConfigPath.UTF8String, _device.fd);
        PSLog(@"[tunnel] engine exited rc=%d", rc);
    }
}

// Exclusions FIRST (upstream, then uncovered DNS resolvers), takeover SECOND.
// Reverse order briefly routes our own upstream connection into the tunnel.
- (BOOL)installRoutesLocked:(NSString *)upstreamIp {
    struct in_addr gw, ipA, peer4;
    inet_pton(AF_INET, _physGw.UTF8String, &gw);
    inet_pton(AF_INET, upstreamIp.UTF8String, &ipA);
    inet_pton(AF_INET, kPSNTunPeerIPv4.UTF8String, &peer4);
    int err = 0;

    if (!PSNRoute4Op(true, ipA, -1, gw, _physIdx, &err)) {
        PSLog(@"[tunnel] upstream exclusion %@/32 via %@ failed: %s",
              upstreamIp, _physGw, strerror(err));
        return NO;
    }
    // This is the first exclusion installed, so a full registry here means the
    // registry was never reset - an invariant violation, not a capacity issue.
    // Untracked means teardown would leave this /32 behind, so undo and fail
    // rather than install a route nothing will ever remove.
    if (!PSNTeardownTrackExclusion(ipA, gw, _physIdx)) {
        PSLog(@"[tunnel] teardown registry full at the upstream exclusion; aborting takeover");
        PSNRoute4Op(false, ipA, -1, gw, _physIdx, NULL);
        return NO;
    }
    PSLog(@"[tunnel] exclusion: %@/32 via %@ idx %u", upstreamIp, _physGw, _physIdx);

    for (NSString *dns in [self currentIPv4Resolvers]) {
        struct in_addr d;
        inet_pton(AF_INET, dns.UTF8String, &d);
        if (d.s_addr == ipA.s_addr) { continue; }                 // already excluded
        if (PSNIPv4CoveredByAnyLocalSubnet(d)) { continue; }      // LAN resolver: never tunnelled
        if (!PSNRoute4Op(true, d, -1, gw, _physIdx, &err)) {
            PSLog(@"[tunnel] DNS exclusion %@/32 failed: %s", dns, strerror(err));
            return NO;
        }
        if (!PSNTeardownTrackExclusion(d, gw, _physIdx)) {
            PSLog(@"[tunnel] teardown registry full; resolver %@ excluded but not tracked", dns);
        }
        PSLog(@"[tunnel] exclusion: DNS %@/32 via %@", dns, _physGw);
    }

    unsigned tunIdx = _device.interfaceIndex;
    if (!PSNRoute4Op(true, (struct in_addr){ .s_addr = 0 }, 1, peer4, tunIdx, &err)) {
        PSLog(@"[tunnel] takeover 0.0.0.0/1 failed: %s", strerror(err));
        return NO;
    }
    if (!PSNRoute4Op(true, (struct in_addr){ .s_addr = htonl(0x80000000) }, 1, peer4, tunIdx, &err)) {
        PSLog(@"[tunnel] takeover 128.0.0.0/1 failed: %s", strerror(err));
        PSNRoute4Op(false, (struct in_addr){ .s_addr = 0 }, 1, peer4, tunIdx, NULL);
        return NO;
    }
    PSNTeardownTrackDef1();
    PSLog(@"[tunnel] takeover: 0.0.0.0/1 + 128.0.0.0/1 via %@ (idx %u)",
          _device.interfaceName, tunIdx);

    // IPv6 twin, best-effort. Without it, v6-capable networks would leak past
    // an IPv4-only tunnel (NWConnection happy-eyeballs PREFERS v6).
    if (_device.ipv6Ready) {
        struct in6_addr peer6, any = IN6ADDR_ANY_INIT, hi = IN6ADDR_ANY_INIT;
        inet_pton(AF_INET6, kPSNTunPeerIPv6.UTF8String, &peer6);
        hi.s6_addr[0] = 0x80;
        BOOL a = PSNRoute6Op(true, any, 1, peer6, tunIdx, NULL);
        BOOL b = PSNRoute6Op(true, hi,  1, peer6, tunIdx, NULL);
        if (a && b) {
            PSNTeardownTrackDef1v6();
            PSLog(@"[tunnel] takeover: ::/1 + 8000::/1 via %@", kPSNTunPeerIPv6);
        } else {
            PSNRoute6Op(false, any, 1, peer6, tunIdx, NULL);
            PSNRoute6Op(false, hi,  1, peer6, tunIdx, NULL);
            PSLog(@"[tunnel] IPv6 takeover failed; continuing IPv4-only (v6 may leak on v6 networks)");
        }
    }
    return YES;
}

// Removes routes, stops the engine, clears the relay, closes the device.
// Does NOT touch _state or the stored upstream. Routes go first so networking
// is restored before the (slower) engine shutdown.
- (void)teardownLocked {
    PSNTunnelTeardown(false);          // same C teardown the signal path uses

    BOOL engineExited = YES;
    if (_engineThread) {
        hev_socks5_tunnel_quit();
        for (int i = 0; i < 40 && !_engineThread.isFinished; i++) {
            usleep(50 * 1000);         // up to 2s for a clean engine exit
        }
        engineExited = _engineThread.isFinished;
        _engineThread = nil;
    }

    [[PSNProxyRelay sharedInstance] clearTunnelUpstream];

    // The engine owns the utun fd for as long as it is running. If it did not
    // exit within the grace period it may still be blocked in read(2) on that
    // descriptor, so closing it here would free the fd NUMBER for immediate
    // reuse - the engine's next read would then hit whatever socket the relay
    // opened next. Leak the descriptor instead: the routes are already gone
    // (PSNTunnelTeardown above), so the orphaned interface carries no traffic,
    // and the cost is bounded to one fd plus one dead utun per failed
    // teardown. If it ever accumulates, KeepAlive restarting the daemon
    // reclaims everything.
    if (engineExited) {
        [_device closeDevice];
    } else {
        PSLog(@"[tunnel] engine thread still running after 2s; abandoning utun fd instead of closing it");
        [_device abandonDevice];
    }
    _device = nil;
}

- (void)stopProbeTimerLocked {
    if (_probeTimer) {
        dispatch_source_cancel(_probeTimer);
        _probeTimer = nil;
    }
}

- (void)armProbeTimerLocked {
    if (_probeTimer) { return; }
    // Created ON _stateQ: probe cycles are serialized with start/stop by
    // construction and can never see a half-installed tunnel.
    _probeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _stateQ);
    dispatch_source_set_timer(_probeTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kProbeInterval * NSEC_PER_SEC)),
        (uint64_t)(kProbeInterval * NSEC_PER_SEC), (uint64_t)(1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_probeTimer, ^{
        typeof(self) self_ = weakSelf;
        if (!self_) { return; }
        if (self_->_state == PSNTunnelStateRunning)   { [self_ probeRunningLocked]; }
        else if (self_->_state == PSNTunnelStateSuspended) { [self_ probeSuspendedLocked]; }
    });
    dispatch_resume(_probeTimer);
}

#pragma mark - health / recovery (always on _stateQ)

- (void)probeRunningLocked {
    // A dead engine means a blackholed tunnel even though the probe target is
    // reachable - the probe bypasses the tunnel via the /32 exclusion.
    if (_engineThread.isFinished) {
        PSLog(@"[tunnel] engine died; failing open");
        [self failOpenLocked];
        return;
    }
    NSString *detail = nil;
    int fd = PSNConnectWithTimeout(_upIp, _upPort, kProbeTimeout, &detail);
    if (fd >= 0) {
        close(fd);
        _consecFails = 0;
        return;
    }
    _consecFails++;
    PSLog(@"[tunnel] health probe %d/%d failed: %@", _consecFails, kProbeMaxFails, detail);
    if (_consecFails >= kProbeMaxFails) {
        [self failOpenLocked];
    }
}

- (void)failOpenLocked {
    PSLog(@"[tunnel] FAIL-OPEN: tearing tunnel down, cooperative mode resumes");
    [self teardownLocked];
    _state = PSNTunnelStateSuspended;
    _consecFails = 0;
    [self armProbeTimerLocked];        // retry every interval while suspended
    PSNTunnelPostStateChanged();       // handler re-applies cooperative mode
}

- (void)probeSuspendedLocked {
    PSLog(@"[tunnel] retrying tunnel start (suspended)");
    if ([self startLockedWithHost:_upHost port:_upPort user:_upUser pass:_upPass]) {
        PSNTunnelPostStateChanged();   // recovered; handler clears SC keys again
    }
}

#pragma mark - start/stop

// The whole bring-up. Must run on _stateQ. Returns YES iff state is Running
// at the end. On any failure: tears down, enters Suspended, returns NO.
- (BOOL)startLockedWithHost:(NSString *)host port:(int)port
                       user:(NSString *)user pass:(NSString *)pass {
    // 1) Read the physical default route FIRST. The exclusions point at this
    //    gateway; a moved gateway (Wi-Fi switch) forces a restart even when
    //    host:port is unchanged.
    struct in_addr gw; unsigned idx = 0; char ifname[IFNAMSIZ];
    if (!PSNDefaultRoute4(&gw, &idx, ifname, sizeof(ifname))) {
        PSLog(@"[tunnel] no IPv4 default route; cannot start");
        return NO;
    }
    char gwStr[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &gw, gwStr, sizeof(gwStr));
    NSString *gwNs = [NSString stringWithUTF8String:gwStr];

    if (_state == PSNTunnelStateRunning) {
        BOOL sameUpstream = [host isEqualToString:_upHost] && (port == _upPort);
        BOOL sameGateway  = [gwNs isEqualToString:_physGw] && (idx == _physIdx);
        if (sameUpstream && sameGateway) { return YES; }
        PSLog(@"[tunnel] %@ changed; restarting", sameUpstream ? @"gateway" : @"upstream");
        [self teardownLocked];
        _state = PSNTunnelStateStopped;
    } else if (_state == PSNTunnelStateSuspended) {
        [self teardownLocked];         // suspended keeps nothing up, but be sure
        // State STAYS Suspended here: it becomes Running only at the end of a
        // successful start (below). We reach this branch from
        // probeSuspendedLocked; if this attempt fails, leaving Suspended in
        // place is what makes the probe retry - storing Stopped would
        // silently kill auto-recovery (the probe only acts on
        // Running/Suspended).
    }

    // 2) Resolve BEFORE any tunnel route exists. A lookup done later would
    //    itself be tunnelled.
    NSString *ip = [self resolveHostToIPv4:host];
    if (!ip) { return NO; }

    PSLog(@"[tunnel] physical default: via %@ dev %s (idx %u); upstream %@ -> %@",
          gwNs, ifname, idx, host, ip);

    // 3) Device.
    _device = [PSNTunnelDevice new];
    if (![_device openDevice] || ![_device configureInterfaces]) {
        [_device closeDevice]; _device = nil;
        return NO;
    }

    // 4) Relay must be serving before any packet can arrive. Dial by IP.
    [[PSNProxyRelay sharedInstance] startIfNeeded];
    [[PSNProxyRelay sharedInstance] configureTunnelUpstreamAddress:ip
                                                              port:port
                                                          username:user
                                                          password:pass];

    // 5) Engine config + thread, with a short settle window: a config or init
    //    error makes hev_socks5_tunnel_main return immediately.
    if (![self writeEngineConfig]) { [self teardownLocked]; return NO; }
    _engineThread = [[NSThread alloc] initWithTarget:self
                                            selector:@selector(engineThreadMain)
                                              object:nil];
    _engineThread.name = @"io.ymuu.proxyswitcherngd.engine";
    [_engineThread start];
    usleep((useconds_t)(kEngineSettleSec * 1000000));
    if (_engineThread.isFinished) {
        PSLog(@"[tunnel] engine exited during startup; refusing to install routes");
        [self teardownLocked];
        return NO;
    }

    // 6) Routes: exclusions first, takeover second.
    _physGw = [gwNs copy]; _physIdx = idx;
    if (![self installRoutesLocked:ip]) {
        [self teardownLocked];
        return NO;
    }

    _upHost = [host copy]; _upPort = port;
    _upUser = [user copy]; _upPass = [pass copy];
    _upIp = [ip copy];
    _state = PSNTunnelStateRunning;
    _consecFails = 0;
    [self armProbeTimerLocked];
    PSLog(@"[tunnel] ACTIVE via %@ (%@:%d)", _device.interfaceName, host, port);
    return YES;
}

- (BOOL)startWithUpstreamHost:(NSString *)host
                         port:(int)port
                     username:(NSString *)user
                     password:(NSString *)pass {
    if (host.length == 0 || port <= 0) { return NO; }
    __block BOOL ok;
    dispatch_sync(_stateQ, ^{
        ok = [self startLockedWithHost:host port:port user:user pass:pass];
        if (!ok && self->_state != PSNTunnelStateRunning) {
            // Start failure still means "wanted": park in suspended so the
            // probe retries instead of waiting for the next prefs event.
            self->_state = PSNTunnelStateSuspended;
            self->_upHost = [host copy]; self->_upPort = port;
            self->_upUser = [user copy]; self->_upPass = [pass copy];
            [self armProbeTimerLocked];
        }
    });
    return ok;
}

- (void)stop {
    dispatch_sync(_stateQ, ^{
        if (_state == PSNTunnelStateStopped && !_device) { return; }
        [self stopProbeTimerLocked];
        [self teardownLocked];
        _state = PSNTunnelStateStopped;
        _consecFails = 0;
        _upHost = nil; _upPort = 0; _upUser = nil; _upPass = nil;
        _upIp = nil; _physGw = nil; _physIdx = 0;
        PSLog(@"[tunnel] stopped");
    });
}

- (void)clearSuspension {
    dispatch_sync(_stateQ, ^{
        if (_state != PSNTunnelStateSuspended) { return; }
        PSLog(@"[tunnel] suspension cleared by user action");
        [self stopProbeTimerLocked];
        _state = PSNTunnelStateStopped;   // stored upstream kept; start overwrites
    });
}

@end
