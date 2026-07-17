#import "PSNCredentialStore.h"
#import <Security/Security.h>

static NSString * const kAccessGroup = @"io.ymuu.proxyswitcherng";

@implementation PSNCredential @end

@implementation PSNCredentialStore

+ (CFStringRef)protocolForKind:(PSNProxyKind)kind {
    // HTTPSProxy covers the CONNECT/HTTPS proxy; SOCKS for SOCKS5.
    return (kind == PSNProxyKindSOCKS) ? kSecAttrProtocolSOCKS : kSecAttrProtocolHTTPSProxy;
}

+ (NSMutableDictionary *)baseQueryForHost:(NSString *)host port:(int)port kind:(PSNProxyKind)kind {
    return [@{
        (id)kSecClass:            (id)kSecClassInternetPassword,
        (id)kSecAttrAccessGroup:  kAccessGroup,
        (id)kSecAttrServer:       host ?: @"",
        (id)kSecAttrPort:         @(port),
        (id)kSecAttrProtocol:     (__bridge id)[self protocolForKind:kind],
    } mutableCopy];
}

+ (BOOL)upsertHost:(NSString *)host port:(int)port kind:(PSNProxyKind)kind
          username:(NSString *)user password:(NSString *)pass {
    NSMutableDictionary *query = [self baseQueryForHost:host port:port kind:kind];
    // Delete any existing item first (simplest correct upsert).
    SecItemDelete((__bridge CFDictionaryRef)query);
    query[(id)kSecAttrAccount] = user ?: @"";
    query[(id)kSecValueData]   = [(pass ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    query[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    if (st != errSecSuccess) {
        NSLog(@"[proxyswitcherngd] keychain add failed: OSStatus=%d", (int)st);
    }
    return st == errSecSuccess;
}

+ (PSNCredential *)lookupHost:(NSString *)host port:(int)port kind:(PSNProxyKind)kind {
    NSMutableDictionary *query = [self baseQueryForHost:host port:port kind:kind];
    query[(id)kSecReturnAttributes] = @YES;
    query[(id)kSecReturnData]       = @YES;
    query[(id)kSecMatchLimit]       = (id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st != errSecSuccess) {
        if (st != errSecItemNotFound) {
            NSLog(@"[proxyswitcherngd] keychain lookup failed: OSStatus=%d", (int)st);
        }
        return nil;
    }
    NSDictionary *item = (__bridge_transfer NSDictionary *)result;
    PSNCredential *cred = [PSNCredential new];
    cred.username = item[(id)kSecAttrAccount] ?: @"";
    NSData *data = item[(id)kSecValueData];
    cred.password = data ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"") : @"";
    return cred;
}

+ (BOOL)deleteHost:(NSString *)host port:(int)port kind:(PSNProxyKind)kind {
    NSMutableDictionary *query = [self baseQueryForHost:host port:port kind:kind];
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef)query);
    return (st == errSecSuccess || st == errSecItemNotFound);
}

@end
