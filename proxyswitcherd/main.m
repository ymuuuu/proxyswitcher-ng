#import "MBWiFiProxyHandler.h"
#import <string.h>

static BOOL PSExpect(NSString *input, BOOL wantOK, NSString *wantHost, int wantPort) {
    NSString *host = nil; NSNumber *port = nil;
    BOOL ok = [MBWiFiProxyHandler parseHostPort:input host:&host port:&port];
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
    fprintf(stderr, "[selftest] %s (%d failures)\n", fails ? "OVERALL FAIL" : "OVERALL PASS", fails);
    return fails ? 1 : 0;
}

static void settingsChanged(CFNotificationCenterRef center,
                            void *observer,
                            CFStringRef name,
                            const void *object,
                            CFDictionaryRef userInfo) {
    NSLog(@"[proxyswitcherngd] received notification: io.ymuu.proxyswitcherng/settingschanged");
    [[MBWiFiProxyHandler sharedInstance] applyFromPreferences];
}

static void networkChanged(CFNotificationCenterRef center,
                           void *observer,
                           CFStringRef name,
                           const void *object,
                           CFDictionaryRef userInfo) {
    NSLog(@"[proxyswitcherngd] received notification: com.apple.system.config.network_change");
    [[MBWiFiProxyHandler sharedInstance] applyFromPreferences];
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

    [[MBWiFiProxyHandler sharedInstance] applyFromPreferences];

    CFRunLoopRun();
    return 0;
}
