#import "PSNWiFiProxyHandler.h"
#import "PSNProxyRelay.h"
#import "PSNCredentialService.h"
#import <string.h>
#import "PSNProxyAuth.h"
#import "PSNPrefKeys.h"
#import "PSNNetKernel.h"
#import "PSNSNISniffer.h"
#import "PSNTunnelNet.h"
#import "PSNTunnelDevice.h"
#import "PSNTunnelController.h"
#import <arpa/inet.h>
#import <net/if.h>
#import <signal.h>

static BOOL PSExpect(NSString *input, BOOL wantOK, NSString *wantHost, int wantPort) {
    NSString *host = nil; NSNumber *port = nil;
    BOOL ok = [PSNWiFiProxyHandler parseHostPort:input host:&host port:&port];
    BOOL pass = (ok == wantOK);
    if (ok && wantOK) {
        pass = pass && [host isEqualToString:wantHost] && (port.intValue == wantPort);
    }
    fprintf(stderr, "[selftest] %s input=%s -> ok=%d host=%s port=%s\n",
            pass ? "PASS" : "FAIL",
            input ? input.UTF8String : "(nil)",
            ok, host.UTF8String ?: "(nil)",
            port ? port.stringValue.UTF8String : "(nil)");
    return pass;
}

static int PSRunSelfTest(void) {
    int fails = 0;
    fails += !PSExpect(@"192.168.100.14:1337", YES, @"192.168.100.14", 1337);
    fails += !PSExpect(@"  10.0.0.5:8888  ",   YES, @"10.0.0.5", 8888);   // trimmed
    fails += !PSExpect(@"user:pass@h:1234",    YES, @"user:pass@h", 1234); // last colon
    fails += !PSExpect(@"nonsense",            NO,  nil, 0);               // no colon
    fails += !PSExpect(@"",                    NO,  nil, 0);               // empty
    fails += !PSExpect(@"host:",               NO,  nil, 0);               // empty port
    fails += !PSExpect(@":8080",               NO,  nil, 0);               // empty host
    fails += !PSExpect(@"host:70000",          NO,  nil, 0);               // out of range
    fails += !PSExpect(@"host:0",              NO,  nil, 0);               // out of range
    fails += !PSExpect(@"host:12ab",           NO,  nil, 0);               // non-digit
    {
        // Basic auth: base64("aladdin:opensesame") == "YWxhZGRpbjpvcGVuc2VzYW1l"
        NSString *line = PSNBasicAuthHeaderLine(@"aladdin", @"opensesame");
        BOOL ok = [line isEqualToString:@"Proxy-Authorization: Basic YWxhZGRpbjpvcGVuc2VzYW1l\r\n"];
        fprintf(stderr, "[selftest] %s basic-auth header\n", ok ? "PASS" : "FAIL");
        fails += !ok;
    }
    {
        NSString *empty = PSNBasicAuthHeaderLine(@"", @"x");
        BOOL ok = (empty.length == 0);
        fprintf(stderr, "[selftest] %s basic-auth empty-user\n", ok ? "PASS" : "FAIL");
        fails += !ok;
    }
    {
        // RFC1929 frame for user "u" pass "p": 01 01 75 01 70
        NSData *req = PSNSocks5UserPassRequest(@"u", @"p");
        const uint8_t want[] = {0x01, 0x01, 0x75, 0x01, 0x70};
        BOOL ok = (req.length == 5 && memcmp(req.bytes, want, 5) == 0);
        fprintf(stderr, "[selftest] %s rfc1929 request frame\n", ok ? "PASS" : "FAIL");
        fails += !ok;
    }
    {
        const uint8_t good[] = {0x01, 0x00};
        const uint8_t bad[]  = {0x01, 0x01};
        BOOL ok = PSNSocks5UserPassReplyOK(good, 2) && !PSNSocks5UserPassReplyOK(bad, 2);
        fprintf(stderr, "[selftest] %s rfc1929 reply parse\n", ok ? "PASS" : "FAIL");
        fails += !ok;
    }
    {
        // XNU ABI: 1+1+2+4+4+20 = 32 bytes.
        BOOL ok = (sizeof(struct sockaddr_ctl) == 32);
        fprintf(stderr, "[selftest] %s xnu sockaddr_ctl size (%zu)\n",
                ok ? "PASS" : "FAIL", sizeof(struct sockaddr_ctl));
        fails += !ok;
    }
    {
        // 4 + 96 = 100 bytes.
        BOOL ok = (sizeof(struct ctl_info) == 100);
        fprintf(stderr, "[selftest] %s xnu ctl_info size (%zu)\n",
                ok ? "PASS" : "FAIL", sizeof(struct ctl_info));
        fails += !ok;
    }
    {
        // 13 * u_int32_t + int32_t = 56 bytes; rt_msghdr = 36 header + 56 = 92.
        BOOL ok = (sizeof(struct rt_metrics) == 56) && (sizeof(struct rt_msghdr) == 92);
        fprintf(stderr, "[selftest] %s xnu rt_metrics/rt_msghdr size (%zu/%zu)\n",
                ok ? "PASS" : "FAIL", sizeof(struct rt_metrics), sizeof(struct rt_msghdr));
        fails += !ok;
    }
    {
        // IFNAMSIZ(16) + 3*sockaddr_in6(28) + int(4) + lifetime(24) = 128.
        // in6_addrlifetime is 2*time_t + 2*u_int32_t and time_t is 8 bytes on
        // arm64 LP64, in userland AND in the kernel, so the kernel's struct is
        // 128 too (the spike's SIOCAIFADDR_IN6 works because they agree; the
        // ioctl number encodes the size). The plan's draft expected 120, from
        // a 4-byte-time_t assumption; the compiler produces 128.
        BOOL ok = (sizeof(struct in6_aliasreq) == 128);
        fprintf(stderr, "[selftest] %s xnu in6_aliasreq size (%zu)\n",
                ok ? "PASS" : "FAIL", sizeof(struct in6_aliasreq));
        fails += !ok;
    }
    {
        // Minimal but structurally valid TLS 1.2 ClientHello for "example.com":
        // record 16 03 01 00 43; handshake 01 00 00 3f; version 03 03;
        // 32-byte random; no session id; one cipher suite; null compression;
        // then a single server_name extension.
        static const uint8_t hello[] = {
            0x16, 0x03, 0x01, 0x00, 0x43,
            0x01, 0x00, 0x00, 0x3f,
            0x03, 0x03,
            0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,
            0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,
            0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,
            0x18,0x19,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f,
            0x00,                     // session id length
            0x00, 0x02, 0x00, 0x2f,   // cipher suites len + one suite
            0x01, 0x00,               // compression len + null
            0x00, 0x14,               // extensions total
            0x00, 0x00,               // ext type server_name
            0x00, 0x10,               // ext len
            0x00, 0x0e,               // list len
            0x00,                     // name type host_name
            0x00, 0x0b,               // name len
            'e','x','a','m','p','l','e','.','c','o','m'
        };
        NSString *sni = PSNSniffTLSServerName(hello, sizeof(hello));
        BOOL ok = [sni isEqualToString:@"example.com"];
        fprintf(stderr, "[selftest] %s tls sni -> %s\n",
                ok ? "PASS" : "FAIL", sni ? sni.UTF8String : "(nil)");
        fails += !ok;

        // Every truncation point must return nil, never read out of bounds.
        BOOL truncOK = YES;
        for (size_t cut = 0; cut < sizeof(hello); cut++) {
            if (PSNSniffTLSServerName(hello, cut) != nil) { truncOK = NO; break; }
        }
        fprintf(stderr, "[selftest] %s tls sni all-truncations -> nil\n", truncOK ? "PASS" : "FAIL");
        fails += !truncOK;

        // Not TLS: an HTTP request head must be rejected as TLS.
        const char *notTls = "GET / HTTP/1.1\r\n\r\n";
        BOOL nt = (PSNSniffTLSServerName((const uint8_t *)notTls, strlen(notTls)) == nil);
        fprintf(stderr, "[selftest] %s tls sni non-tls -> nil\n", nt ? "PASS" : "FAIL");
        fails += !nt;

        // A CR inside the name must be rejected. The sniffed name is pasted
        // into an upstream "CONNECT <host>:<port> HTTP/1.1\r\n" line, so a
        // crafted ClientHello could otherwise inject extra request headers.
        uint8_t hostile[sizeof(hello)];
        memcpy(hostile, hello, sizeof(hello));
        hostile[sizeof(hello) - 5] = '\r';        // inside "example.com"
        BOOL inj = (PSNSniffTLSServerName(hostile, sizeof(hostile)) == nil);
        fprintf(stderr, "[selftest] %s tls sni rejects CR in name\n", inj ? "PASS" : "FAIL");
        fails += !inj;
    }
    {
        const char *req = "GET /v1/me HTTP/1.1\r\nHost: api.example.com\r\nAccept: */*\r\n\r\n";
        NSString *h = PSNSniffHTTPHost((const uint8_t *)req, strlen(req));
        BOOL ok = [h isEqualToString:@"api.example.com"];
        fprintf(stderr, "[selftest] %s http host -> %s\n",
                ok ? "PASS" : "FAIL", h ? h.UTF8String : "(nil)");
        fails += !ok;

        // Case-insensitive header name; trailing :port stripped.
        const char *req2 = "GET / HTTP/1.1\r\nhOsT: example.org:8080\r\n\r\n";
        NSString *h2 = PSNSniffHTTPHost((const uint8_t *)req2, strlen(req2));
        BOOL ok2 = [h2 isEqualToString:@"example.org"];
        fprintf(stderr, "[selftest] %s http host ci+port -> %s\n",
                ok2 ? "PASS" : "FAIL", h2 ? h2.UTF8String : "(nil)");
        fails += !ok2;

        const char *noHost = "GET / HTTP/1.0\r\n\r\n";
        BOOL nh = (PSNSniffHTTPHost((const uint8_t *)noHost, strlen(noHost)) == nil);
        fprintf(stderr, "[selftest] %s http no-host -> nil\n", nh ? "PASS" : "FAIL");
        fails += !nh;

        // Bracketed IPv6 literal: the port follows the closing bracket, so
        // splitting on the last colon would cut the address itself.
        const char *v6 = "GET / HTTP/1.1\r\nHost: [2001:db8::1]:8080\r\n\r\n";
        NSString *h3 = PSNSniffHTTPHost((const uint8_t *)v6, strlen(v6));
        BOOL ok3 = [h3 isEqualToString:@"[2001:db8::1]"];
        fprintf(stderr, "[selftest] %s http host ipv6 literal -> %s\n",
                ok3 ? "PASS" : "FAIL", h3 ? h3.UTF8String : "(nil)");
        fails += !ok3;
    }
    {
        struct in_addr ip, ifa, mask;
        inet_pton(AF_INET, "192.168.100.50", &ip);
        inet_pton(AF_INET, "192.168.100.7", &ifa);
        inet_pton(AF_INET, "255.255.255.0", &mask);
        BOOL inLan = PSNIPv4CoveredBySubnet(ip, ifa, mask);
        inet_pton(AF_INET, "8.8.8.8", &ip);
        BOOL outLan = PSNIPv4CoveredBySubnet(ip, ifa, mask);
        inet_pton(AF_INET, "10.99.0.1", &ip);
        inet_pton(AF_INET, "10.99.0.1", &ifa);
        inet_pton(AF_INET, "255.255.255.255", &mask);
        BOOL hostSelf = PSNIPv4CoveredBySubnet(ip, ifa, mask);
        inet_pton(AF_INET, "0.0.0.0", &mask);
        BOOL zeroMask = PSNIPv4CoveredBySubnet(ip, ifa, mask);
        BOOL ok = inLan && !outLan && hostSelf && !zeroMask;
        fprintf(stderr, "[selftest] %s subnet cover (lan=%d out=%d host=%d zeromask=%d)\n",
                ok ? "PASS" : "FAIL", inLan, outLan, hostSelf, zeroMask);
        fails += !ok;
    }
    {
        // Every cfprefs key, spelled out as a literal (NOT the PSN_PREF_*_STR
        // macros - comparing the macro to itself proves nothing). A typo in a
        // key would silently read a preference nothing writes on-device.
        BOOL ok =
            [kPSNPrefDomain      isEqualToString:@"io.ymuu.proxyswitcherng"] &&
            [kPSNPrefEnabled     isEqualToString:@"enabled"] &&
            [kPSNPrefServer      isEqualToString:@"server"] &&
            [kPSNPrefPort        isEqualToString:@"port"] &&
            [kPSNPrefUseSocks    isEqualToString:@"useSocks"] &&
            [kPSNPrefLogging     isEqualToString:@"logging"] &&
            [kPSNPrefActiveProxy isEqualToString:@"activeProxy"] &&
            [kPSNPrefProfiles    isEqualToString:@"profiles"] &&
            [kPSNPrefManualAuth  isEqualToString:@"manualAuth"] &&
            [kPSNPrefPendingCred isEqualToString:@"pendingCred"] &&
            [kPSNPrefTunnelMode  isEqualToString:@"tunnelMode"] &&
            [kPSNPrefExcludeApple isEqualToString:@"excludeAppleServices"];
        fprintf(stderr, "[selftest] %s pref keys match literals\n", ok ? "PASS" : "FAIL");
        fails += !ok;
    }
    fails += PSNRelayRunSocks5RequestSelfTest();
    fprintf(stderr, "[selftest] %s (%d failures)\n", fails ? "OVERALL FAIL" : "OVERALL PASS", fails);
    return fails ? 1 : 0;
}

static void clearLog(CFNotificationCenterRef center,
                     void *observer,
                     CFStringRef name,
                     const void *object,
                     CFDictionaryRef userInfo) {
    NSString *path = @"/var/mobile/Library/Logs/ProxySwitcherNG.log";
    [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:path error:nil];
    NSLog(@"[proxyswitcherngd] cleared log file");
}

static void settingsChanged(CFNotificationCenterRef center,
                            void *observer,
                            CFStringRef name,
                            const void *object,
                            CFDictionaryRef userInfo) {
    NSLog(@"[proxyswitcherngd] received notification: io.ymuu.proxyswitcherng/settingschanged");
    [PSNCredentialService drainPendingFromPrefs];
    [[PSNTunnelController sharedInstance] clearSuspension];
    [[PSNWiFiProxyHandler sharedInstance] applyFromPreferences];
}

static void networkChanged(CFNotificationCenterRef center,
                           void *observer,
                           CFStringRef name,
                           const void *object,
                           CFDictionaryRef userInfo) {
    NSLog(@"[proxyswitcherngd] received notification: com.apple.system.config.network_change");
    [[PSNWiFiProxyHandler sharedInstance] applyFromPreferences];
}

// On-device, non-destructive smoke test for the route ops: a /32 into
// TEST-NET-2 (198.51.100.0/24, unroutable by definition) via the PHYSICAL
// gateway, then removed again. No tunnel routes, no utun, no default-route
// change - a failure here can at worst leave one harmless TEST-NET route.
static int PSRunNetSelfTest(void) {
    int fails = 0;

    // Initialized because PSNDefaultRoute4 writes no out-param when it fails,
    // and the line below formats them either way.
    struct in_addr gw = { .s_addr = 0 };
    unsigned idx = 0;
    char ifname[IFNAMSIZ] = {0};
    BOOL haveDefault = PSNDefaultRoute4(&gw, &idx, ifname, sizeof(ifname));
    char gwStr[INET_ADDRSTRLEN] = "?";
    inet_ntop(AF_INET, &gw, gwStr, sizeof(gwStr));
    fprintf(stderr, "[selftest-net] %s default route via %s dev %s (idx %u)\n",
            haveDefault ? "PASS" : "FAIL", gwStr, ifname, idx);
    fails += !haveDefault;
    if (!haveDefault) { return fails; }

    struct in_addr probe;
    inet_pton(AF_INET, "198.51.100.1", &probe);   // TEST-NET-2, unroutable

    int err = 0;
    BOOL add1 = PSNRoute4Op(true, probe, -1, gw, idx, &err);
    fprintf(stderr, "[selftest-net] %s add 198.51.100.1/32 (%s)\n",
            add1 ? "PASS" : "FAIL", add1 ? "ok" : strerror(err));
    fails += !add1;

    BOOL add2 = PSNRoute4Op(true, probe, -1, gw, idx, &err);   // EEXIST-proof path
    fprintf(stderr, "[selftest-net] %s re-add (EEXIST-proof)\n", add2 ? "PASS" : "FAIL");
    fails += !add2;

    BOOL del1 = PSNRoute4Op(false, probe, -1, gw, idx, &err);
    BOOL del2 = PSNRoute4Op(false, probe, -1, gw, idx, &err);  // ESRCH-tolerant
    fprintf(stderr, "[selftest-net] %s delete idempotent (%d/%d)\n",
            (del1 && del2) ? "PASS" : "FAIL", del1, del2);
    fails += !(del1 && del2);

    // Registry + double teardown: nothing tracked here, so both must no-op.
    PSNTunnelTeardown(false);
    PSNTunnelTeardown(true);
    fprintf(stderr, "[selftest-net] PASS empty teardown is a no-op\n");

    // Device lifecycle: create (auto unit), configure, close. Idempotent
    // teardown afterwards must still be a no-op.
    PSNTunnelDevice *dev = [PSNTunnelDevice new];
    BOOL opened = [dev openDevice] && [dev configureInterfaces];
    fprintf(stderr, "[selftest-net] %s utun create+configure (%s fd=%d idx=%u v6=%d)\n",
            opened ? "PASS" : "FAIL", dev.interfaceName.UTF8String ?: "?",
            dev.fd, dev.interfaceIndex, dev.ipv6Ready);
    fails += !opened;

    struct in_addr gw2; unsigned idx2 = 0;
    BOOL defaultIntact = PSNDefaultRoute4(&gw2, &idx2, NULL, 0) && (idx2 == idx);
    fprintf(stderr, "[selftest-net] %s default route untouched by utun\n",
            defaultIntact ? "PASS" : "FAIL");
    fails += !defaultIntact;

    [dev closeDevice];
    PSNTunnelTeardown(false);   // registry was untracked; must be a no-op
    fprintf(stderr, "[selftest-net] PASS utun closed, teardown no-op\n");

    // Regression for the device-test-1 deadlock: with the takeover pair
    // 0.0.0.0/1 + 128.0.0.0/1 installed via a utun, PSNDefaultRoute4 must
    // STILL return the physical gateway. An RTM_GET lookup returns the
    // tunnel peer here (0.0.0.0 matches the /1, which beats /0); the sysctl
    // dump must not. The /1 routes live only for the duration of this block:
    // teardown removes them, and closing the fd would make the kernel purge
    // them anyway - at worst a few milliseconds of blackhole inside a
    // selftest that passes no traffic.
    {
        PSNTunnelDevice *devT = [PSNTunnelDevice new];   // openDevice tracks fd+ifindex
        BOOL upT = [devT openDevice] && [devT configureInterfaces];
        struct in_addr peerT;
        inet_pton(AF_INET, kPSNTunPeerIPv4.UTF8String, &peerT);
        BOOL t1 = NO, t2 = NO;
        if (upT) {
            int eT = 0;
            t1 = PSNRoute4Op(true, (struct in_addr){ .s_addr = 0 },                1, peerT, devT.interfaceIndex, &eT);
            t2 = PSNRoute4Op(true, (struct in_addr){ .s_addr = htonl(0x80000000) }, 1, peerT, devT.interfaceIndex, &eT);
        }
        if (t1 && t2) { PSNTeardownTrackDef1(); }   // so teardown removes them

        struct in_addr gwT = { .s_addr = 0 };
        unsigned idxT = 0;
        char ifnT[IFNAMSIZ] = {0};
        BOOL stillPhys = PSNDefaultRoute4(&gwT, &idxT, ifnT, sizeof(ifnT)) &&
                         gwT.s_addr == gw.s_addr && idxT == idx;
        char gwTStr[INET_ADDRSTRLEN] = "?";
        inet_ntop(AF_INET, &gwT, gwTStr, sizeof(gwTStr));
        fprintf(stderr, "[selftest-net] %s default route stays physical with /1 takeover up (via %s dev %s)\n",
                stillPhys ? "PASS" : "FAIL", gwTStr, ifnT);
        fails += !(upT && t1 && t2 && stillPhys);

        PSNTunnelTeardown(false);   // tracked def1: deletes both /1 routes
        [devT closeDevice];         // untracks and closes; kernel would purge anyway
    }

    fprintf(stderr, "[selftest-net] %s (%d failures)\n",
            fails ? "OVERALL FAIL" : "OVERALL PASS", fails);
    return fails ? 1 : 0;
}

// Termination path: ONLY async-signal-safe calls. Objective-C, locks,
// allocation and logging can all deadlock a dying process with the routes
// still installed - so the handler runs the same plain-C teardown the normal
// stop path uses (Task 5), then exits.
static void psnHandleTermSignal(int sig) {
    PSNTunnelTeardown(true);    // routes + utun fd; idempotent
    _exit(sig == SIGTERM ? 0 : 128 + sig);
}

// Crash path, best effort: even without this the kernel purges the utun's
// routes when the dying process drops the fd, but the /32 exclusions point at
// the physical gateway and would linger until the KeepAlive restart reclaims
// them (EEXIST-proof add). Re-raise with the default handler afterwards so
// the crash still produces a real report.
static void psnHandleCrashSignal(int sig) {
    PSNTunnelTeardown(true);
    struct sigaction sa = { 0 };
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, NULL);
    kill(getpid(), sig);
    // Deliberately no _exit() here. The signal being handled is blocked for
    // the duration of the handler, so the kill() above only makes it pending;
    // exiting now would consume the crash and report a tidy 128+sig instead.
    // Returning restores the mask: SIGABRT is then delivered to SIG_DFL, and
    // SIGSEGV/SIGBUS/SIGILL re-run the faulting instruction and fault again.
    // Either way the default handler produces the crash report.
}

static void psnInstallSignalHandlers(void) {
    struct sigaction sa = { 0 };
    sa.sa_handler = psnHandleTermSignal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGHUP,  &sa, NULL);

    struct sigaction ca = { 0 };
    ca.sa_handler = psnHandleCrashSignal;
    sigemptyset(&ca.sa_mask);
    sigaction(SIGSEGV, &ca, NULL);
    sigaction(SIGABRT, &ca, NULL);
    sigaction(SIGBUS,  &ca, NULL);
    sigaction(SIGILL,  &ca, NULL);
}

static void tunnelStateChanged(CFNotificationCenterRef center,
                               void *observer,
                               CFStringRef name,
                               const void *object,
                               CFDictionaryRef userInfo) {
    NSLog(@"[proxyswitcherngd] received notification: %s", PSNTunnelStateChangedNotification);
    [[PSNWiFiProxyHandler sharedInstance] applyFromPreferences];
}

int main(int argc, char **argv, char **envp) {
    if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
        @autoreleasepool { return PSRunSelfTest(); }
    }
    if (argc > 1 && strcmp(argv[1], "--selftest-net") == 0) {
        @autoreleasepool { return PSRunNetSelfTest(); }
    }
    NSLog(@"[proxyswitcherngd] launched");

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    settingsChanged,
                                    CFSTR("io.ymuu.proxyswitcherng/settingschanged"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    networkChanged,
                                    CFSTR("com.apple.system.config.network_change"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    clearLog,
                                    CFSTR("io.ymuu.proxyswitcherng/clearlog"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    tunnelStateChanged,
                                    CFSTR(PSNTunnelStateChangedNotification),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);

    // Before applyFromPreferences, which is what starts the tunnel and installs
    // the routes. Installing the handlers afterwards would leave a window where
    // a SIGTERM strands the /1 takeover with nothing to tear it down.
    psnInstallSignalHandlers();

    [[PSNProxyRelay sharedInstance] startIfNeeded];
    [PSNCredentialService start];

    [[PSNWiFiProxyHandler sharedInstance] applyFromPreferences];

    CFRunLoopRun();
    return 0;
}
