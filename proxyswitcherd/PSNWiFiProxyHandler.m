#import "PSNWiFiProxyHandler.h"
#import "PSNCredentialStore.h"
#import "PSNProxyRelay.h"
#import "PSNLog.h"
#import "PSNHostPort.h"
#import "PSNPrefKeys.h"
#import "PSNTunnelController.h"
#import "SCNetworkHeader.h"
#import <CoreFoundation/CoreFoundation.h>

@interface NSDictionary<KeyType, ObjectType> (Getters)

- (nullable NSString *)stringForKeySafely:(nullable KeyType)key;
- (nullable NSNumber *)numberForKeySafely:(nullable KeyType)key;

@end

@implementation NSDictionary (Getters)

- (NSString *)stringForKeySafely:(id)key {
    id string = [self objectForKey:key];
    if ([string isKindOfClass:[NSString class]]) { return string; }
    if ([string isKindOfClass:[NSNumber class]]) { return [NSString stringWithFormat:@"%@", string]; }
    return nil;
}

- (NSNumber *)numberForKeySafely:(id)key {
    id number = [self objectForKey:key];
    if ([number isKindOfClass:[NSNumber class]]) { return number; }
    if ([number isKindOfClass:[NSString class]]) { return [self numberFromString:(NSString *)number]; }
    return nil;
}

- (NSNumber *)numberFromString:(NSString *)string {
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
    return [formatter numberFromString:string];
}

@end

@interface PSNWiFiProxyHandler ()
- (void)updateProxy:(BOOL)enabled server:(NSString *)server port:(NSNumber *)port type:(NSString *)type;
- (void)logSCError:(NSString *)callName;
- (BOOL)isWiFiServiceByInterface:(NSDictionary *)service;
- (NSString *)interfaceInfoString:(NSDictionary *)service;
- (NSString *)findWiFiServiceKey:(SCPreferencesRef)prefs;
- (NSMutableDictionary *)deepCopyServices:(NSDictionary *)services;
- (BOOL)shouldChangeProxyDict:(NSDictionary *)proxyDict withServer:(NSString *)server port:(NSNumber *)port type:(NSString *)type;
- (NSNumber *)asNumber:(id)value;
@end

@implementation PSNWiFiProxyHandler

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static PSNWiFiProxyHandler *handler;
    dispatch_once(&onceToken, ^{
        handler = [[PSNWiFiProxyHandler alloc] init];
    });
    return handler;
}

- (void)applyFromPreferences {
    CFStringRef appID = CFSTR(PSN_PREF_DOMAIN_STR);
    CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);

    NSNumber *enabled = (__bridge_transfer NSNumber *)CFPreferencesCopyValue(CFSTR(PSN_PREF_ENABLED_STR), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
    NSString *server = (__bridge_transfer NSString *)CFPreferencesCopyValue(CFSTR(PSN_PREF_SERVER_STR), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
    // PSEditTextCell stores the port as an NSString; SCPreferences requires a
    // CFNumber for HTTPPort/HTTPSPort. Coerce so we never write a string (which
    // is ignored by the network stack) and never send -isEqualToNumber: to a
    // string later (which crashes).
    NSNumber *port = [self asNumber:(__bridge_transfer id)CFPreferencesCopyValue(CFSTR(PSN_PREF_PORT_STR), appID, CFSTR("mobile"), kCFPreferencesAnyHost)];
    NSString *activeProxy = (__bridge_transfer NSString *)CFPreferencesCopyValue(CFSTR(PSN_PREF_ACTIVEPROXY_STR), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
    NSNumber *logging = (__bridge_transfer NSNumber *)CFPreferencesCopyValue(CFSTR(PSN_PREF_LOGGING_STR), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
    NSNumber *useSocks = (__bridge_transfer NSNumber *)CFPreferencesCopyValue(CFSTR(PSN_PREF_USESOCKS_STR), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
    NSNumber *tunnelMode = (__bridge_transfer NSNumber *)CFPreferencesCopyValue(CFSTR(PSN_PREF_TUNNELMODE_STR), appID, CFSTR("mobile"), kCFPreferencesAnyHost);

    NSString *source = @"cfprefsd";
    if (!enabled && !server && !port && !activeProxy) {
        source = @"fallback-file";
        NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/io.ymuu.proxyswitcherng.plist"];
        if (!preferences) {
            preferences = @{};
        }
        enabled = [preferences objectForKey:kPSNPrefEnabled];
        server = [preferences stringForKeySafely:kPSNPrefServer];
        port = [preferences numberForKeySafely:kPSNPrefPort];
        activeProxy = [preferences stringForKeySafely:kPSNPrefActiveProxy];
        logging = [preferences objectForKey:kPSNPrefLogging];
        useSocks = [preferences numberForKeySafely:kPSNPrefUseSocks];
        tunnelMode = [preferences numberForKeySafely:kPSNPrefTunnelMode];
    }

    PSNLogSetEnabled(logging ? [logging boolValue] : NO);

    PSLog(@"[proxyswitcherngd] prefs source=%@ enabled=%@ server=%@ port=%@ logging=%@", source, enabled ?: @"(nil)", server ?: @"(nil)", port ?: @"(nil)", logging ?: @"(nil)");

    if ([activeProxy isEqualToString:@"__none__"]) {
        PSLog(@"[proxyswitcherngd] activeProxy=__none__; forcing proxy off");
        server = nil;
        port = nil;
    } else if (activeProxy.length > 0) {
        NSString *pHost = nil; NSNumber *pPort = nil;
        if ([PSNWiFiProxyHandler parseHostPort:activeProxy host:&pHost port:&pPort]) {
            PSLog(@"[proxyswitcherngd] activeProxy=%@ -> server=%@ port=%@", activeProxy, pHost, pPort);
            server = pHost;
            port = pPort;
        } else {
            PSLog(@"[proxyswitcherngd] activeProxy=%@ malformed; using manual server/port", activeProxy);
        }
    }

    NSString *type = [useSocks boolValue] ? @"socks" : @"http";
    BOOL enabledBool = enabled ? [enabled boolValue] : YES;
    BOOL shouldEnable = enabledBool && (server.length > 0) && (port != nil);

    BOOL wantTunnel = shouldEnable && (tunnelMode ? [tunnelMode boolValue] : NO);
    if (wantTunnel && [type isEqualToString:@"socks"]) {
        // The tunnel bridge speaks HTTP CONNECT upstream (that is where SNI
        // recovery lives). Refuse loudly rather than silently misbehave.
        PSLog(@"[proxyswitcherngd] tunnel mode requires an HTTP proxy; staying cooperative while useSocks is on");
        wantTunnel = NO;
    }

    PSNTunnelController *tun = [PSNTunnelController sharedInstance];
    if (wantTunnel && ![tun suspended]) {
        PSNCredential *cred = [PSNCredentialStore lookupHost:server
                                                        port:port.intValue
                                                        kind:PSNProxyKindHTTP];
        if ([tun startWithUpstreamHost:server
                                  port:port.intValue
                              username:cred.username
                              password:cred.password]) {
            // The tunnel carries ALL traffic. Leaving the SC proxy keys set as
            // well would double-proxy cooperative apps, so clear them.
            [[PSNProxyRelay sharedInstance] clearUpstream];
            [self updateProxy:NO server:nil port:nil type:type];
            PSLog(@"[proxyswitcherngd] tunnel mode active; system proxy keys cleared");
            return;
        }
        // Fail-open: fall through to cooperative mode. The controller parked
        // itself in suspended and retries on its own; it posts
        // tunnelstatechanged when the tunnel comes up.
        PSLog(@"[proxyswitcherngd] tunnel start failed; falling back to system proxy");
    } else if (!wantTunnel) {
        [tun stop];
    }
    // (wantTunnel && suspended): cooperative applies below; retry is armed.

    NSString *effServer = server;
    NSNumber *effPort = port;
    if (shouldEnable) {
        BOOL socks = [type isEqualToString:@"socks"];
        PSNProxyKind kind = socks ? PSNProxyKindSOCKS : PSNProxyKindHTTP;
        PSNCredential *cred = [PSNCredentialStore lookupHost:server port:port.intValue kind:kind];
        if (cred && cred.username.length > 0) {
            [[PSNProxyRelay sharedInstance] configureUpstreamHost:server port:port.intValue
                                                            socks:socks
                                                         username:cred.username
                                                         password:cred.password];
            effServer = @"127.0.0.1";
            effPort = @(kPSNRelayPort);
            PSLog(@"[proxyswitcherngd] auth profile: routing %@ via relay 127.0.0.1:%d", server, kPSNRelayPort);
        } else {
            [[PSNProxyRelay sharedInstance] clearUpstream];
        }
    } else {
        [[PSNProxyRelay sharedInstance] clearUpstream];
    }

    [self updateProxy:shouldEnable server:effServer port:effPort type:type];
}

- (void)updateProxy:(BOOL)enabled server:(NSString *)server port:(NSNumber *)port type:(NSString *)type {
    PSLog(@"[proxyswitcherngd] applyFromPreferences: enabled=%d server=%@ port=%@", enabled, server ?: @"(nil)", port ?: @"(nil)");

    SCPreferencesRef prefs = SCPreferencesCreate(NULL, CFSTR("proxyswitcherngd"), NULL);
    if (prefs == NULL) {
        PSLog(@"[proxyswitcherngd] SCPreferencesCreate returned NULL");
        [self logSCError:@"SCPreferencesCreate"];
        return;
    }
    NSLog(@"[proxyswitcherngd] SCPreferencesCreate returned non-NULL prefs");

    Boolean locked = SCPreferencesLock(prefs, true);
    PSLog(@"[proxyswitcherngd] SCPreferencesLock returned %s", locked ? "true" : "false");
    if (!locked) {
        [self logSCError:@"SCPreferencesLock"];
    }

    NSString *wifiServiceKey = [self findWiFiServiceKey:prefs];
    if (wifiServiceKey == nil) {
        if (locked) {
            Boolean unlocked = SCPreferencesUnlock(prefs);
            PSLog(@"[proxyswitcherngd] SCPreferencesUnlock returned %s", unlocked ? "true" : "false");
            if (!unlocked) { [self logSCError:@"SCPreferencesUnlock"]; }
        }
        CFRelease(prefs);
        return;
    }

    CFPropertyListRef servicesCF = SCPreferencesGetValue(prefs, kSCPrefNetworkServices);
    if (servicesCF == NULL) {
        PSLog(@"[proxyswitcherngd] SCPreferencesGetValue(prefs, kSCPrefNetworkServices) returned NULL");
        [self logSCError:@"SCPreferencesGetValue(kSCPrefNetworkServices)"];
        if (locked) {
            Boolean unlocked = SCPreferencesUnlock(prefs);
            PSLog(@"[proxyswitcherngd] SCPreferencesUnlock returned %s", unlocked ? "true" : "false");
            if (!unlocked) { [self logSCError:@"SCPreferencesUnlock"]; }
        }
        CFRelease(prefs);
        return;
    }
    NSLog(@"[proxyswitcherngd] SCPreferencesGetValue(prefs, kSCPrefNetworkServices) returned non-NULL");

    NSDictionary *services = (__bridge NSDictionary *)servicesCF;
    NSMutableDictionary *nservices = [self deepCopyServices:services];
    NSMutableDictionary *proxies = nservices[wifiServiceKey][cfs2nss(kSCEntNetProxies)];
    if (proxies == nil) {
        PSLog(@"[proxyswitcherngd] Wi-Fi service has no Proxies dict; aborting");
        if (locked) {
            Boolean unlocked = SCPreferencesUnlock(prefs);
            PSLog(@"[proxyswitcherngd] SCPreferencesUnlock returned %s", unlocked ? "true" : "false");
            if (!unlocked) { [self logSCError:@"SCPreferencesUnlock"]; }
        }
        CFRelease(prefs);
        return;
    }

    BOOL shouldWrite = NO;
    if (enabled) {
        if (![self shouldChangeProxyDict:proxies withServer:server port:port type:type]) {
            PSLog(@"[proxyswitcherngd] proxy state already matches desired state; skipping write");
        } else {
            PSLog(@"[proxyswitcherngd] setting %@ proxy server=%@ port=%@", type, server, port);
            if ([type isEqualToString:@"socks"]) {
                // SOCKS mode: set SOCKS keys, remove any HTTP/HTTPS keys so the
                // two modes never coexist on the service.
                proxies[cfs2nss(kSCPropNetProxiesSOCKSEnable)] = @(1);
                proxies[cfs2nss(kSCPropNetProxiesSOCKSProxy)] = server;
                proxies[cfs2nss(kSCPropNetProxiesSOCKSPort)] = port;
                [proxies removeObjectForKey:cfs2nss(kSCPropNetProxiesHTTPEnable)];
                [proxies removeObjectForKey:cfs2nss(kSCPropNetProxiesHTTPProxy)];
                [proxies removeObjectForKey:cfs2nss(kSCPropNetProxiesHTTPPort)];
                [proxies removeObjectForKey:cfs2nss(kSCPropNetProxiesHTTPSEnable)];
                [proxies removeObjectForKey:cfs2nss(kSCPropNetProxiesHTTPSProxy)];
                [proxies removeObjectForKey:cfs2nss(kSCPropNetProxiesHTTPSPort)];
            } else {
                // HTTP mode: set HTTP + HTTPS keys, remove any SOCKS keys.
                proxies[cfs2nss(kSCPropNetProxiesHTTPEnable)] = @(1);
                proxies[cfs2nss(kSCPropNetProxiesHTTPProxy)] = server;
                proxies[cfs2nss(kSCPropNetProxiesHTTPPort)] = port;
                proxies[cfs2nss(kSCPropNetProxiesHTTPSEnable)] = @(1);
                proxies[cfs2nss(kSCPropNetProxiesHTTPSProxy)] = server;
                proxies[cfs2nss(kSCPropNetProxiesHTTPSPort)] = port;
                [proxies removeObjectForKey:cfs2nss(kSCPropNetProxiesSOCKSEnable)];
                [proxies removeObjectForKey:cfs2nss(kSCPropNetProxiesSOCKSProxy)];
                [proxies removeObjectForKey:cfs2nss(kSCPropNetProxiesSOCKSPort)];
            }
            shouldWrite = YES;
        }
    } else {
        if (proxies.count == 0) {
            PSLog(@"[proxyswitcherngd] proxy already cleared; skipping write");
        } else {
            PSLog(@"[proxyswitcherngd] clearing all proxy entries");
            [proxies removeAllObjects];
            shouldWrite = YES;
        }
    }

    if (shouldWrite) {
        Boolean setOk = SCPreferencesSetValue(prefs, kSCPrefNetworkServices, (__bridge CFPropertyListRef)nservices);
        PSLog(@"[proxyswitcherngd] SCPreferencesSetValue returned %s", setOk ? "true" : "false");
        if (!setOk) { [self logSCError:@"SCPreferencesSetValue"]; }

        Boolean commitOk = SCPreferencesCommitChanges(prefs);
        PSLog(@"[proxyswitcherngd] SCPreferencesCommitChanges returned %s", commitOk ? "true" : "false");
        if (!commitOk) { [self logSCError:@"SCPreferencesCommitChanges"]; }

        Boolean applyOk = SCPreferencesApplyChanges(prefs);
        PSLog(@"[proxyswitcherngd] SCPreferencesApplyChanges returned %s", applyOk ? "true" : "false");
        if (!applyOk) { [self logSCError:@"SCPreferencesApplyChanges"]; }
    }

    if (locked) {
        Boolean unlocked = SCPreferencesUnlock(prefs);
        PSLog(@"[proxyswitcherngd] SCPreferencesUnlock returned %s", unlocked ? "true" : "false");
        if (!unlocked) { [self logSCError:@"SCPreferencesUnlock"]; }
    }

    CFRelease(prefs);
    PSLog(@"[proxyswitcherngd] applyFromPreferences complete");
}

#pragma mark - Helpers

- (void)logSCError:(NSString *)callName {
    int err = SCError();
    const char *errStr = SCErrorString(err);
    PSLog(@"[proxyswitcherngd] %@ failed: SCError=%d (%s)", callName, err, errStr ? errStr : "(null)");
}

- (BOOL)isWiFiServiceByInterface:(NSDictionary *)service {
    NSDictionary *interface = service[@"Interface"];
    if (!interface) { return NO; }
    NSString *hardware = interface[@"Hardware"];
    NSString *type = interface[@"Type"];
    return [hardware isEqualToString:@"AirPort"] || [type isEqualToString:@"IEEE80211"];
}

- (NSString *)interfaceInfoString:(NSDictionary *)service {
    NSDictionary *interface = service[@"Interface"];
    if (!interface) { return @"(no Interface dict)"; }
    return [NSString stringWithFormat:@"Hardware=%@ Type=%@ DeviceName=%@",
            interface[@"Hardware"] ?: @"(null)",
            interface[@"Type"] ?: @"(null)",
            interface[@"DeviceName"] ?: @"(null)"];
}

- (NSString *)findWiFiServiceKey:(SCPreferencesRef)prefs {
    CFStringRef currentSetPath = SCPreferencesGetValue(prefs, kSCPrefCurrentSet);
    if (currentSetPath == NULL) {
        PSLog(@"[proxyswitcherngd] SCPreferencesGetValue(prefs, kSCPrefCurrentSet) returned NULL");
        [self logSCError:@"SCPreferencesGetValue(kSCPrefCurrentSet)"];
        return nil;
    }
    NSLog(@"[proxyswitcherngd] SCPreferencesGetValue(prefs, kSCPrefCurrentSet) returned non-NULL");

    CFDictionaryRef currentSetCF = SCPreferencesPathGetValue(prefs, currentSetPath);
    if (currentSetCF == NULL) {
        PSLog(@"[proxyswitcherngd] SCPreferencesPathGetValue(prefs, currentSetPath) returned NULL");
        [self logSCError:@"SCPreferencesPathGetValue"];
        return nil;
    }
    NSLog(@"[proxyswitcherngd] SCPreferencesPathGetValue(prefs, currentSetPath) returned non-NULL");

    NSDictionary *currentSet = (__bridge NSDictionary *)currentSetCF;
    NSDictionary *currentSetServices = currentSet[cfs2nss(kSCCompNetwork)][cfs2nss(kSCCompService)];
    NSLog(@"[proxyswitcherngd] currentSet services count: %lu", (unsigned long)currentSetServices.count);

    CFPropertyListRef servicesCF = SCPreferencesGetValue(prefs, kSCPrefNetworkServices);
    if (servicesCF == NULL) {
        PSLog(@"[proxyswitcherngd] SCPreferencesGetValue(prefs, kSCPrefNetworkServices) returned NULL");
        [self logSCError:@"SCPreferencesGetValue(kSCPrefNetworkServices)"];
        return nil;
    }
    NSLog(@"[proxyswitcherngd] SCPreferencesGetValue(prefs, kSCPrefNetworkServices) returned non-NULL");

    NSDictionary *services = (__bridge NSDictionary *)servicesCF;
    for (NSString *key in currentSetServices) {
        NSDictionary *service = services[key];
        NSString *name = service[cfs2nss(kSCPropUserDefinedName)];
        NSString *interfaceInfo = [self interfaceInfoString:service];
        NSLog(@"[proxyswitcherngd] currentSet service candidate key=%@ name=%@ interface=%@",
              key, name ?: @"(null)", interfaceInfo);
        if ([self isWiFiServiceByInterface:service]) {
            NSLog(@"[proxyswitcherngd] selected Wi-Fi service by interface key=%@ name=%@ interface=%@",
                  key, name ?: @"(null)", interfaceInfo);
            return key;
        }
    }
    PSLog(@"[proxyswitcherngd] no Wi-Fi service found in current set by interface (Hardware=AirPort or Type=IEEE80211)");
    return nil;
}

- (NSMutableDictionary *)deepCopyServices:(NSDictionary *)services {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:services
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:nil];
    NSMutableDictionary *nservices = [NSPropertyListSerialization propertyListWithData:data
                                                                               options:NSPropertyListMutableContainersAndLeaves
                                                                                format:NULL
                                                                                 error:nil];
    NSLog(@"[proxyswitcherngd] deep-copy services: original=%lu entries, mutable=%lu entries",
          (unsigned long)services.count, (unsigned long)nservices.count);
    return nservices;
}

- (NSNumber *)asNumber:(id)value {
    if ([value isKindOfClass:[NSNumber class]]) { return value; }
    if ([value isKindOfClass:[NSString class]]) { return @([(NSString *)value integerValue]); }
    return nil;
}

+ (BOOL)parseHostPort:(NSString *)value host:(NSString **)outHost port:(NSNumber **)outPort {
    return PSNParseHostPort(value, outHost, outPort);
}

// Type-strict, crash-safe field checks: a value of the wrong class (e.g. a
// string port left by an older build) counts as "not equal", forcing a clean
// rewrite, and -isEqualTo* is only ever sent to the right class.
- (BOOL)value:(id)value isNumber:(NSNumber *)expected {
    return [value isKindOfClass:[NSNumber class]] && [(NSNumber *)value isEqualToNumber:expected];
}
- (BOOL)value:(id)value isString:(NSString *)expected {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value isEqualToString:expected];
}

- (BOOL)shouldChangeProxyDict:(NSDictionary *)proxyDict withServer:(NSString *)server port:(NSNumber *)port type:(NSString *)type {
    if ([type isEqualToString:@"socks"]) {
        BOOL socksMatches =
            [self value:proxyDict[cfs2nss(kSCPropNetProxiesSOCKSEnable)] isNumber:@1]     &&
            [self value:proxyDict[cfs2nss(kSCPropNetProxiesSOCKSProxy)]  isString:server] &&
            [self value:proxyDict[cfs2nss(kSCPropNetProxiesSOCKSPort)]   isNumber:port];
        BOOL httpAbsent =
            proxyDict[cfs2nss(kSCPropNetProxiesHTTPProxy)] == nil &&
            proxyDict[cfs2nss(kSCPropNetProxiesHTTPSProxy)] == nil;
        return !(socksMatches && httpAbsent);
    }
    BOOL httpMatches =
        [self value:proxyDict[cfs2nss(kSCPropNetProxiesHTTPEnable)]  isNumber:@1]     &&
        [self value:proxyDict[cfs2nss(kSCPropNetProxiesHTTPProxy)]   isString:server] &&
        [self value:proxyDict[cfs2nss(kSCPropNetProxiesHTTPPort)]    isNumber:port]   &&
        [self value:proxyDict[cfs2nss(kSCPropNetProxiesHTTPSEnable)] isNumber:@1]     &&
        [self value:proxyDict[cfs2nss(kSCPropNetProxiesHTTPSProxy)]  isString:server] &&
        [self value:proxyDict[cfs2nss(kSCPropNetProxiesHTTPSPort)]   isNumber:port];
    BOOL socksAbsent = proxyDict[cfs2nss(kSCPropNetProxiesSOCKSProxy)] == nil;
    return !(httpMatches && socksAbsent);
}

@end
