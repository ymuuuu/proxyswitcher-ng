#import "PSNWiFiProxyHandler.h"
#import "PSNProxyRelay.h"
#import "PSNCredentialService.h"
#import <string.h>
#import "PSNProxyAuth.h"

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
