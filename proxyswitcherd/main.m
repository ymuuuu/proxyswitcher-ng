#import "MBWiFiProxyHandler.h"

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
