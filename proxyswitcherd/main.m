#import "PSNWiFiProxyHandler.h"
#import "PSNProxyRelay.h"
#import "PSNCredentialService.h"
#import <string.h>
#import "PSNProxyAuth.h"
#import "PSNNetKernel.h"
#import "PSNSNISniffer.h"

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

int main(int argc, char **argv, char **envp) {
    if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
        @autoreleasepool { return PSRunSelfTest(); }
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

    [[PSNProxyRelay sharedInstance] startIfNeeded];
    [PSNCredentialService start];

    [[PSNWiFiProxyHandler sharedInstance] applyFromPreferences];

    CFRunLoopRun();
    return 0;
}
