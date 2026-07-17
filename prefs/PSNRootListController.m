#import "PSNRootListController.h"
#import "PSNProfileEditController.h"
#import "PSNLogsController.h"
#import "PSNSocketUtil.h"
#import "PSNProxyAuth.h"
#import "PSNCredentialClient.h"
#import "PSNProfileCell.h"
#import <CoreFoundation/CoreFoundation.h>
#import <Preferences/Preferences.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdint.h>

static NSString * const kPrefsDomain = @"io.ymuu.proxyswitcherng";
static NSString * const kSettingsChangedNotification = @"io.ymuu.proxyswitcherng/settingschanged";
static NSString * const kNoneToken = @"__none__";

static NSString * const kProfileKey = @"isProfile";
static NSString * const kManualKey = @"isManual";
static NSString * const kProfileValueKey = @"profileValue";
static NSString * const kProfileIndexKey = @"profileIndex";

static char kLinkURLKey;

static void PSApplyButtonStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	PSNRootListController *controller = (__bridge PSNRootListController *)observer;
	dispatch_async(dispatch_get_main_queue(), ^{
		controller.navigationItem.rightBarButtonItem.enabled = [PSNRootListController isEnabled];
	});
}

// End-to-end reachability target: the Apply test verifies the proxy can actually
// forward to this host, not just that the proxy port is open.
static NSString * const kProbeTargetHost = @"ymuu.me";
static const int kProbeTargetPort = 443;

// SOCKS5 no-auth handshake + CONNECT to the target on an already-connected fd.
// Returns YES on a 0x00 reply; *detail always gets a specific reason.
static BOOL PSProbeSocks5(int fd, NSString *user, NSString *pass, NSString **detail) {
	BOOL wantAuth = (user.length > 0);
	uint8_t greet[4]; size_t glen;
	if (wantAuth) { greet[0]=0x05; greet[1]=0x02; greet[2]=0x00; greet[3]=0x02; glen=4; }
	else          { greet[0]=0x05; greet[1]=0x01; greet[2]=0x00; glen=3; }
	if (!PSNWriteAll(fd, greet, glen)) {
		if (detail) { *detail = [NSString stringWithFormat:@"SOCKS5 greeting write failed: %s", strerror(errno)]; }
		return NO;
	}
	uint8_t methodResp[2] = {0,0};
	if (PSNReadSome(fd, methodResp, 2) < 2) {
		if (detail) { *detail = @"SOCKS5: no method reply (timeout?)"; }
		return NO;
	}
	if (methodResp[0] != 0x05) {
		if (detail) {
			*detail = [NSString stringWithFormat:@"SOCKS5 handshake rejected (ver=0x%02x, method=0x%02x)%@",
				methodResp[0], methodResp[1], methodResp[1] == 0xFF ? @", server requires auth" : @""];
		}
		return NO;
	}
	if (methodResp[1] == 0x02) {
		NSData *auth = PSNSocks5UserPassRequest(user, pass);
		if (!auth || !PSNWriteAll(fd, auth.bytes, auth.length)) {
			if (detail) { *detail = @"SOCKS5 auth write failed"; } return NO;
		}
		uint8_t ar[2];
		if (PSNReadSome(fd, ar, 2) < 2 || !PSNSocks5UserPassReplyOK(ar, 2)) {
			if (detail) { *detail = @"SOCKS5 authentication rejected"; } return NO;
		}
	} else if (methodResp[1] != 0x00) {
		if (detail) { *detail = [NSString stringWithFormat:
			@"SOCKS5 handshake rejected (method=0x%02x)%@", methodResp[1],
			methodResp[1]==0xFF ? @", server requires a method we don't offer" : @""]; }
		return NO;
	}
	const char *th = kProbeTargetHost.UTF8String;
	size_t thl = strlen(th);
	uint8_t req[262];
	size_t i = 0;
	req[i++] = 0x05; req[i++] = 0x01; req[i++] = 0x00; req[i++] = 0x03;
	req[i++] = (uint8_t)thl;
	memcpy(req + i, th, thl); i += thl;
	req[i++] = (uint8_t)((kProbeTargetPort >> 8) & 0xFF);
	req[i++] = (uint8_t)(kProbeTargetPort & 0xFF);
	if (!PSNWriteAll(fd, req, i)) {
		if (detail) { *detail = [NSString stringWithFormat:@"SOCKS5 CONNECT write failed: %s", strerror(errno)]; }
		return NO;
	}

	uint8_t rep[10] = {0};
	if (PSNReadSome(fd, rep, sizeof(rep)) < 2) {
		if (detail) { *detail = @"SOCKS5: no CONNECT reply (timeout?)"; }
		return NO;
	}
	uint8_t code = rep[1];
	if (code == 0x00) {
		if (detail) { *detail = [NSString stringWithFormat:@"SOCKS5 CONNECT %@:%d OK", kProbeTargetHost, kProbeTargetPort]; }
		return YES;
	}
	static const char *socksErrs[] = {"success", "general SOCKS server failure", "connection not allowed",
		"network unreachable", "host unreachable", "connection refused", "TTL expired",
		"command not supported", "address type not supported"};
	NSString *m = (code <= 8) ? [NSString stringWithUTF8String:socksErrs[code]] : @"unknown";
	if (detail) { *detail = [NSString stringWithFormat:@"SOCKS5 CONNECT failed: %@ (0x%02x)", m, code]; }
	return NO;
}

// HTTP CONNECT to the target on an already-connected fd. Returns YES on 200;
// *detail always gets the status line or a specific reason.
static BOOL PSProbeHttpConnect(int fd, NSString *user, NSString *pass, NSString **detail) {
	NSString *authLine = PSNBasicAuthHeaderLine(user, pass);
	NSString *reqStr = [NSString stringWithFormat:
		@"CONNECT %@:%d HTTP/1.1\r\nHost: %@:%d\r\n%@\r\n",
		kProbeTargetHost, kProbeTargetPort, kProbeTargetHost, kProbeTargetPort, authLine];
	const char *req = reqStr.UTF8String;
	if (!PSNWriteAll(fd, req, strlen(req))) {
		if (detail) { *detail = [NSString stringWithFormat:@"HTTP CONNECT write failed: %s", strerror(errno)]; }
		return NO;
	}

	char buf[256];
	memset(buf, 0, sizeof(buf));
	if (PSNReadSome(fd, buf, sizeof(buf) - 1) <= 0) {
		if (detail) { *detail = @"HTTP proxy: no response (timeout?)"; }
		return NO;
	}

	NSString *resp = [NSString stringWithUTF8String:buf] ?: @"";
	NSString *statusLine = [[resp componentsSeparatedByString:@"\r\n"] firstObject] ?: resp;
	NSArray *parts = [statusLine componentsSeparatedByString:@" "];
	NSInteger code = (parts.count >= 2) ? [parts[1] integerValue] : 0;
	if (code == 200) {
		if (detail) { *detail = [NSString stringWithFormat:@"HTTP CONNECT %@:%d -> %@", kProbeTargetHost, kProbeTargetPort, statusLine]; }
		return YES;
	}
	if (code == 407) {
		if (detail) { *detail = @"HTTP proxy authentication failed (407)"; }
		return NO;
	}
	if (detail) { *detail = [NSString stringWithFormat:@"HTTP CONNECT failed: %@", statusLine.length ? statusLine : resp]; }
	return NO;
}

// Verify the proxy actually forwards by reaching kProbeTargetHost through it.
// Speaks the proxy protocol on a raw socket (HTTP CONNECT or SOCKS5), so there is
// no NSURLSession direct-fallback false positive. *detail always gets a specific
// reason, success or failure.
static BOOL PSProbeThroughProxy(NSString *proxyHost, int proxyPort, BOOL useSocks,
        NSString *user, NSString *pass, NSTimeInterval timeout, NSString **detail) {
	int fd = PSNConnectWithTimeout(proxyHost, proxyPort, timeout, detail);
	if (fd < 0) { return NO; }
	BOOL ok = useSocks ? PSProbeSocks5(fd, user, pass, detail)
					   : PSProbeHttpConnect(fd, user, pass, detail);
	close(fd);
	return ok;
}

@interface PSNRootListController ()

+ (BOOL)parseHostPort:(NSString *)value host:(NSString **)outHost port:(NSNumber **)outPort;

@property (nonatomic, strong) PSSpecifier *manualAuthToggleSpec;
@property (nonatomic, strong) PSSpecifier *manualUserSpec;
@property (nonatomic, strong) PSSpecifier *manualPassSpec;
@property (nonatomic, copy) NSString *manualUsername;
@property (nonatomic, copy) NSString *manualPassword;

- (UIButton *)iconButtonNamed:(NSString *)name URLString:(NSString *)URLString;
- (void)openLink:(UIButton *)sender;

@end

@implementation PSNRootListController

+ (NSArray *)readProfiles {
	CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	CFArrayRef cfProfiles = CFPreferencesCopyValue(CFSTR("profiles"), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	if (!cfProfiles) { return @[]; }
	NSArray *profiles = (__bridge_transfer NSArray *)cfProfiles;
	if (![profiles isKindOfClass:[NSArray class]]) { return @[]; }
	return profiles;
}

+ (void)writeProfiles:(NSArray *)profiles {
	CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSetValue(CFSTR("profiles"), (__bridge CFPropertyListRef)(profiles ?: @[]), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
}

+ (NSString *)activeProxy {
	CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	CFStringRef cfValue = CFPreferencesCopyValue(CFSTR("activeProxy"), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	if (!cfValue) { return nil; }
	NSString *value = (__bridge_transfer NSString *)cfValue;
	if (![value isKindOfClass:[NSString class]]) { return nil; }
	return value;
}

+ (void)setActiveProxy:(NSString *)activeProxy {
	CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSetValue(CFSTR("activeProxy"), (__bridge CFPropertyListRef)(activeProxy ?: @""), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
}

+ (void)setUseSocks:(BOOL)useSocks {
	CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSetValue(CFSTR("useSocks"), (__bridge CFPropertyListRef)(@(useSocks)), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
}

+ (BOOL)isEnabled {
	CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	CFBooleanRef cfValue = CFPreferencesCopyValue(CFSTR("enabled"), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	if (!cfValue) { return YES; }
	if (CFGetTypeID(cfValue) != CFBooleanGetTypeID()) {
		CFRelease(cfValue);
		return YES;
	}
	BOOL enabled = CFBooleanGetValue(cfValue);
	CFRelease(cfValue);
	return enabled;
}

+ (void)postSettingsChanged {
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
										 (__bridge CFStringRef)kSettingsChangedNotification,
										 NULL,
										 NULL,
										 YES);
}

+ (void)addOrUpdateProfile:(NSDictionary *)profile atIndex:(NSInteger)index {
	NSMutableArray *profiles = [[self readProfiles] mutableCopy] ?: [NSMutableArray array];
	NSString *oldValue = nil;
	if (index >= 0 && index < (NSInteger)profiles.count) {
		oldValue = [profiles[index] objectForKey:@"value"];
		profiles[index] = profile;
	} else {
		[profiles addObject:profile];
	}
	[self writeProfiles:profiles];

	NSString *activeProxy = [self activeProxy] ?: @"";
	NSString *newValue = profile[@"value"] ?: @"";
	if (oldValue && [oldValue isEqualToString:activeProxy] && ![newValue isEqualToString:activeProxy]) {
		[self setActiveProxy:newValue];
		[self postSettingsChanged];
	}
}

+ (void)deleteProfileAtIndex:(NSInteger)index {
	NSMutableArray *profiles = [[self readProfiles] mutableCopy] ?: [NSMutableArray array];
	if (index < 0 || index >= (NSInteger)profiles.count) { return; }
	NSString *deletedValue = [profiles[index] objectForKey:@"value"];
	[profiles removeObjectAtIndex:index];
	[self writeProfiles:profiles];

	NSString *activeProxy = [self activeProxy] ?: @"";
	if ([deletedValue isEqualToString:activeProxy]) {
		[self setActiveProxy:@""];
		[self postSettingsChanged];
	}
}

+ (BOOL)parseHostPort:(NSString *)value host:(NSString **)outHost port:(NSNumber **)outPort {
	if (![value isKindOfClass:[NSString class]]) { return NO; }
	NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	NSString *trimmed = [value stringByTrimmingCharactersInSet:ws];
	if (trimmed.length == 0) { return NO; }

	NSRange colon = [trimmed rangeOfString:@":" options:NSBackwardsSearch];
	if (colon.location == NSNotFound) { return NO; }

	NSString *host = [[trimmed substringToIndex:colon.location] stringByTrimmingCharactersInSet:ws];
	NSString *portStr = [[trimmed substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:ws];
	if (host.length == 0 || portStr.length == 0) { return NO; }

	NSCharacterSet *digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
	NSCharacterSet *nonDigits = [digits invertedSet];
	if ([portStr rangeOfCharacterFromSet:nonDigits].location != NSNotFound) { return NO; }

	NSInteger port = [portStr integerValue];
	if (port < 1 || port > 65535) { return NO; }

	if (outHost) { *outHost = host; }
	if (outPort) { *outPort = @(port); }
	return YES;
}

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
		if (!_specifiers) {
			_specifiers = [NSMutableArray array];
		}

		[self injectManualAuthSpecifiers];

		NSArray *profiles = [PSNRootListController readProfiles];
		NSArray *profileSpecs = [self profileSpecifiersForProfiles:profiles];

		// Insert the Profiles section above the Diagnostics group so the final
		// order is Enabled, Proxy Server, Profiles, Diagnostics (logging/Logs),
		// About. Diagnostics stays in Root.plist to keep its pref auto-wiring.
		NSUInteger insertAt = _specifiers.count;
		for (NSUInteger i = 0; i < _specifiers.count; i++) {
			PSSpecifier *s = _specifiers[i];
			if ([s.name isEqualToString:@"Diagnostics"]) { insertAt = i; break; }
		}
		NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertAt, profileSpecs.count)];
		[_specifiers insertObjects:profileSpecs atIndexes:indexes];

		[_specifiers addObjectsFromArray:[self aboutSpecifiers]];
	}

	return _specifiers;
}

- (void)injectManualAuthSpecifiers {
	PSSpecifier *useSocks = nil;
	for (PSSpecifier *s in _specifiers) {
		if ([[s propertyForKey:PSKeyNameKey] isEqualToString:@"useSocks"]) {
			useSocks = s;
			break;
		}
	}
	if (!useSocks) { return; }

	BOOL manualAuth = [self readManualAuthBool];

	PSSpecifier *toggle = [PSSpecifier preferenceSpecifierNamed:@"Use authentication"
														 target:self
															set:@selector(setManualAuth:specifier:)
															get:@selector(readManualAuth:)
														 detail:NULL
															cell:PSSwitchCell
															 edit:NULL];
	[toggle setProperty:@"manualAuth" forKey:PSKeyNameKey];
	[toggle setProperty:@(manualAuth) forKey:PSDefaultValueKey];
	self.manualAuthToggleSpec = toggle;

	PSSpecifier *user = [PSSpecifier preferenceSpecifierNamed:@"Username"
													 target:self
														set:@selector(setManualAuthValue:specifier:)
														get:@selector(readManualAuthValue:)
													   detail:NULL
														cell:PSEditTextCell
														 edit:NULL];
	[user setProperty:@"manualUsername" forKey:PSKeyNameKey];
	self.manualUserSpec = user;

	PSSpecifier *pass = [PSSpecifier preferenceSpecifierNamed:@"Password"
													 target:self
														set:@selector(setManualAuthValue:specifier:)
														get:@selector(readManualAuthValue:)
													   detail:NULL
														cell:PSSecureEditTextCell
														 edit:NULL];
	[pass setProperty:@"manualPassword" forKey:PSKeyNameKey];
	self.manualPassSpec = pass;

	NSUInteger idx = [_specifiers indexOfObjectIdenticalTo:useSocks];
	if (idx == NSNotFound) { idx = _specifiers.count - 1; }
	[_specifiers insertObject:toggle atIndex:idx + 1];

	if (manualAuth) {
		NSString *server = [self readManualServer];
		NSNumber *port = [self readManualPort];
		BOOL socks = [self readManualUseSocks];
		if (server.length > 0 && port != nil) {
			NSString *u = nil, *p = nil;
			if ([PSNCredentialClient getHost:server port:port.intValue socks:socks username:&u password:&p]) {
				self.manualUsername = u ?: @"";
				// Password is never prefilled; field always starts blank on reload.
			}
		}
		[user setProperty:self.manualUsername ?: @"" forKey:PSDefaultValueKey];
		[pass setProperty:@"" forKey:PSDefaultValueKey];
		[_specifiers insertObject:user atIndex:idx + 2];
		[_specifiers insertObject:pass atIndex:idx + 3];
	} else {
		self.manualUsername = @"";
		self.manualPassword = @"";
	}
}

- (NSString *)readManualServer {
	CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	NSString *server = (__bridge_transfer NSString *)CFPreferencesCopyValue(CFSTR("server"), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	return [server isKindOfClass:[NSString class]] ? server : @"";
}

- (NSNumber *)readManualPort {
	CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	id portValue = (__bridge_transfer id)CFPreferencesCopyValue(CFSTR("port"), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	NSInteger port = 0;
	if ([portValue isKindOfClass:[NSNumber class]]) {
		port = [(NSNumber *)portValue integerValue];
	} else if ([portValue isKindOfClass:[NSString class]]) {
		port = [(NSString *)portValue integerValue];
	}
	if (port > 0 && port <= 65535) { return @(port); }
	return nil;
}

- (BOOL)readManualUseSocks {
	CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	id useSocksVal = (__bridge_transfer id)CFPreferencesCopyValue(CFSTR("useSocks"), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	return [useSocksVal isKindOfClass:[NSNumber class]] ? [(NSNumber *)useSocksVal boolValue] : NO;
}

- (BOOL)readManualAuthBool {
	CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	CFBooleanRef cfValue = CFPreferencesCopyValue(CFSTR("manualAuth"), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	if (!cfValue) { return NO; }
	if (CFGetTypeID(cfValue) != CFBooleanGetTypeID()) {
		CFRelease(cfValue);
		return NO;
	}
	BOOL result = CFBooleanGetValue(cfValue);
	CFRelease(cfValue);
	return result;
}

- (id)readManualAuth:(PSSpecifier *)specifier {
	return @([self readManualAuthBool]);
}

- (void)setManualAuth:(id)value specifier:(PSSpecifier *)specifier {
	BOOL on = [value boolValue];
	CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSetValue(CFSTR("manualAuth"), (__bridge CFPropertyListRef)@(on), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);

	if (!on) {
		[self deleteManualCredentials];
		self.manualUsername = @"";
		self.manualPassword = @"";
	}

	[PSNRootListController postSettingsChanged];

	if (on) {
		// Prefill the username from the keychain so an existing credential shows up
		// immediately when auth is re-enabled (mirrors the edit-profile screen).
		NSString *server = [self readManualServer];
		NSNumber *port = [self readManualPort];
		if (server.length > 0 && port != nil) {
			NSString *u = nil, *p = nil;
			if ([PSNCredentialClient getHost:server port:port.intValue socks:[self readManualUseSocks] username:&u password:&p]) {
				self.manualUsername = u ?: @"";
			}
		}
		if ([_specifiers indexOfObjectIdenticalTo:self.manualUserSpec] == NSNotFound) {
			[self insertSpecifier:self.manualUserSpec afterSpecifier:self.manualAuthToggleSpec animated:YES];
		}
		if ([_specifiers indexOfObjectIdenticalTo:self.manualPassSpec] == NSNotFound) {
			[self insertSpecifier:self.manualPassSpec afterSpecifier:self.manualUserSpec animated:YES];
		}
	} else {
		if ([_specifiers indexOfObjectIdenticalTo:self.manualUserSpec] != NSNotFound) {
			[self removeSpecifier:self.manualUserSpec animated:YES];
		}
		if ([_specifiers indexOfObjectIdenticalTo:self.manualPassSpec] != NSNotFound) {
			[self removeSpecifier:self.manualPassSpec animated:YES];
		}
	}
}

- (id)readManualAuthValue:(PSSpecifier *)specifier {
	NSString *key = [specifier propertyForKey:PSKeyNameKey];
	if ([key isEqualToString:@"manualUsername"]) { return self.manualUsername ?: @""; }
	if ([key isEqualToString:@"manualPassword"]) { return self.manualPassword ?: @""; }
	return @"";
}

- (void)setManualAuthValue:(id)value specifier:(PSSpecifier *)specifier {
	NSString *key = [specifier propertyForKey:PSKeyNameKey];
	NSString *string = @"";
	if ([value isKindOfClass:[NSString class]]) {
		string = value;
	} else if (value) {
		string = [value description];
	}
	if ([key isEqualToString:@"manualUsername"]) {
		self.manualUsername = string;
	} else if ([key isEqualToString:@"manualPassword"]) {
		self.manualPassword = string;
	}
	[self saveManualCredentials];
}

- (void)saveManualCredentials {
	if (![self readManualAuthBool]) { return; }
	NSString *server = [self readManualServer];
	NSNumber *port = [self readManualPort];
	if (server.length == 0 || port == nil) { return; }
	BOOL socks = [self readManualUseSocks];
	NSString *user = [self.manualUsername stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSString *pass = self.manualPassword ?: @"";
	if (user.length > 0) {
		// Password field is blank on reload; editing the username alone must not
		// wipe the stored password. Preserve the existing keychain password when
		// the user did not type a new one.
		if (pass.length == 0) {
			NSString *eu = nil, *ep = nil;
			if ([PSNCredentialClient getHost:server port:port.intValue socks:socks username:&eu password:&ep] && ep.length > 0) {
				pass = ep;
			}
		}
		[PSNCredentialClient setHost:server port:port.intValue socks:socks username:user password:pass];
	} else {
		[PSNCredentialClient deleteHost:server port:port.intValue socks:socks];
	}
	[PSNRootListController postSettingsChanged];
}

- (void)deleteManualCredentials {
	NSString *server = [self readManualServer];
	NSNumber *port = [self readManualPort];
	if (server.length == 0 || port == nil) { return; }
	BOOL socks = [self readManualUseSocks];
	[PSNCredentialClient deleteHost:server port:port.intValue socks:socks];
}

- (NSArray *)aboutSpecifiers {
	PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"About"];
	return @[group];
}

- (NSArray *)profileSpecifiersForProfiles:(NSArray *)profiles {
	NSMutableArray *specifiers = [NSMutableArray array];

	PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"Profiles"];
	[group setProperty:@"Selected profile overrides manual Server/Port." forKey:PSFooterTextGroupKey];
	[specifiers addObject:group];

	PSSpecifier *none = [PSSpecifier preferenceSpecifierNamed:@"None (no proxy)"
													  target:self
														set:NULL
														get:NULL
													   detail:NULL
														cell:PSButtonCell
														edit:NULL];
	none->action = @selector(selectProfile:);
	[none setProperty:@(YES) forKey:kProfileKey];
	[none setProperty:@(NO) forKey:kManualKey];
	[none setProperty:kNoneToken forKey:kProfileValueKey];
	[none setProperty:@(-1) forKey:kProfileIndexKey];
	[specifiers addObject:none];

	PSSpecifier *manual = [PSSpecifier preferenceSpecifierNamed:@"Manual (Server/Port)"
													   target:self
														set:NULL
														get:NULL
													   detail:NULL
														cell:PSButtonCell
														edit:NULL];
	manual->action = @selector(selectProfile:);
	[manual setProperty:@(YES) forKey:kProfileKey];
	[manual setProperty:@(YES) forKey:kManualKey];
	[manual setProperty:@"" forKey:kProfileValueKey];
	[manual setProperty:@(-1) forKey:kProfileIndexKey];
	[specifiers addObject:manual];

	for (NSInteger i = 0; i < (NSInteger)profiles.count; i++) {
		NSDictionary *profile = profiles[i];
		NSString *name = @"";
		NSString *value = @"";
		NSString *type = @"http";
		if ([profile isKindOfClass:[NSDictionary class]]) {
			name = profile[@"name"] ?: @"";
			value = profile[@"value"] ?: @"";
			if ([profile[@"type"] isEqualToString:@"socks"]) { type = @"socks"; }
		}
		if (name.length == 0) { name = value; }
		if (name.length == 0) { name = @"(untitled)"; }

		NSString *typeLabel = [type isEqualToString:@"socks"] ? @"SOCKS" : @"HTTP";
		NSString *title = [NSString stringWithFormat:@"%@ (%@)", name, value];
		BOOL hasAuth = [profile[@"hasAuth"] boolValue];
		NSString *subtitle = [NSString stringWithFormat:@"%@ · %@", typeLabel, hasAuth ? @"Auth enabled" : @"No auth"];
		PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:title
															  target:self
																set:NULL
																get:NULL
															   detail:NULL
																cell:PSButtonCell
																edit:NULL];
		specifier->action = @selector(selectProfile:);
		[specifier setProperty:@(YES) forKey:kProfileKey];
		[specifier setProperty:@(NO) forKey:kManualKey];
		[specifier setProperty:value forKey:kProfileValueKey];
		[specifier setProperty:@(i) forKey:kProfileIndexKey];
		[specifier setProperty:type forKey:@"psnProfileType"];
		[specifier setProperty:@"PSNProfileCell" forKey:@"cellClass"];
		[specifier setProperty:subtitle forKey:@"psnSubtitle"];
		[specifiers addObject:specifier];
	}

	PSSpecifier *add = [PSSpecifier preferenceSpecifierNamed:@"Add Profile..."
													  target:self
														 set:NULL
														 get:NULL
														detail:NULL
														 cell:PSButtonCell
														 edit:NULL];
	add->action = @selector(addProfile:);
	[specifiers addObject:add];

	return specifiers;
}

- (void)selectProfile:(PSSpecifier *)specifier {
	NSString *value = [specifier propertyForKey:kProfileValueKey] ?: @"";
	[PSNRootListController setActiveProxy:value];
	// Manual row (kManualKey) keeps whatever the manual Type cell set; only a
	// real saved profile carries its own type.
	BOOL isManual = [[specifier propertyForKey:kManualKey] boolValue];
	if (!isManual) {
		NSString *type = [specifier propertyForKey:@"psnProfileType"] ?: @"http";
		[PSNRootListController setUseSocks:[type isEqualToString:@"socks"]];
	}
	[PSNRootListController postSettingsChanged];
	[self reloadSpecifiers];
}

- (void)addProfile:(PSSpecifier *)specifier {
	PSNProfileEditController *editController = [[PSNProfileEditController alloc] init];
	editController.profileIndex = -1;
	editController.profile = nil;
	[self pushController:editController];
}

- (void)editProfile:(PSSpecifier *)specifier {
	NSInteger index = [[specifier propertyForKey:kProfileIndexKey] integerValue];
	NSArray *profiles = [PSNRootListController readProfiles];
	if (index < 0 || index >= (NSInteger)profiles.count) { return; }
	NSDictionary *profile = profiles[index];

	PSNProfileEditController *editController = [[PSNProfileEditController alloc] init];
	editController.profileIndex = index;
	editController.profile = profile;
	[self pushController:editController];
}

- (void)openLogs:(PSSpecifier *)specifier {
	PSNLogsController *logsController = [[PSNLogsController alloc] init];
	[self pushController:logsController];
}

- (void)applyAndVerify:(id)sender {
	if (![PSNRootListController isEnabled]) {
		[PSNRootListController postSettingsChanged];
		return;
	}

	[PSNRootListController postSettingsChanged];

	NSString *activeProxy = [PSNRootListController activeProxy] ?: @"";
	NSString *testHost = nil;
	NSNumber *testPort = nil;

	if ([activeProxy isEqualToString:kNoneToken]) {
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Apply"
																   message:@"Proxy is off (None), nothing to test."
															preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}

	if ([PSNRootListController parseHostPort:activeProxy host:&testHost port:&testPort]) {
		// Real profile selected: use its host:port.
	} else {
		// Manual mode: read server and port from prefs.
		CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
		CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
		NSString *server = (__bridge_transfer NSString *)CFPreferencesCopyValue(CFSTR("server"), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
		if (![server isKindOfClass:[NSString class]]) { server = nil; }
		id portValue = (__bridge_transfer id)CFPreferencesCopyValue(CFSTR("port"), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
		NSInteger port = 0;
		if ([portValue isKindOfClass:[NSNumber class]]) {
			port = [(NSNumber *)portValue integerValue];
		} else if ([portValue isKindOfClass:[NSString class]]) {
			port = [(NSString *)portValue integerValue];
		}
		if (server.length > 0 && port > 0 && port <= 65535) {
			testHost = server;
			testPort = @(port);
		}
	}

	if (!testHost || !testPort) {
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Apply"
																   message:@"No proxy set to test."
															preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}

	NSString *displayHostPort = [NSString stringWithFormat:@"%@:%@", testHost, testPort];
	NSString *hostCopy = testHost;
	int portInt = testPort.intValue;

	CFStringRef appIDc = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSynchronize(appIDc, CFSTR("mobile"), kCFPreferencesAnyHost);
	NSNumber *useSocksNum = (__bridge_transfer NSNumber *)CFPreferencesCopyValue(CFSTR("useSocks"), appIDc, CFSTR("mobile"), kCFPreferencesAnyHost);
	BOOL useSocks = [useSocksNum boolValue];

	NSString *pUser = nil, *pPass = nil;
	[PSNCredentialClient getHost:hostCopy port:portInt socks:useSocks username:&pUser password:&pPass];
	NSString *userCopy = pUser ?: @"";
	NSString *passCopy = pPass ?: @"";

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSString *detail = nil;
		BOOL ok = PSProbeThroughProxy(hostCopy, portInt, useSocks, userCopy, passCopy, 8.0, &detail);
		dispatch_async(dispatch_get_main_queue(), ^{
			NSString *typeStr = useSocks ? @"SOCKS5" : @"HTTP";
			NSString *message = ok
				? [NSString stringWithFormat:@"%@ proxy %@ reached %@:%d.\n\n%@", typeStr, displayHostPort, kProbeTargetHost, kProbeTargetPort, detail ?: @""]
				: [NSString stringWithFormat:@"%@ proxy %@ could not reach %@:%d.\n\n%@", typeStr, displayHostPort, kProbeTargetHost, kProbeTargetPort, detail ?: @"unknown error"];
			UIAlertController *alert = [UIAlertController alertControllerWithTitle:(ok ? @"Apply: OK" : @"Apply: Failed") message:message preferredStyle:UIAlertControllerStyleAlert];
			[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
			[self presentViewController:alert animated:YES completion:nil];
		});
	});
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
	PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
	if ([[specifier propertyForKey:kProfileKey] boolValue]) {
		NSString *value = [specifier propertyForKey:kProfileValueKey] ?: @"";
		NSString *activeProxy = [PSNRootListController activeProxy] ?: @"";
		cell.accessoryType = [value isEqualToString:activeProxy] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
	PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
	if (![[specifier propertyForKey:kProfileKey] boolValue] ||
		[[specifier propertyForKey:kManualKey] boolValue]) {
		return nil;
	}
	NSInteger index = [[specifier propertyForKey:kProfileIndexKey] integerValue];
	if (index < 0) { return nil; }

	return [UIContextMenuConfiguration configurationWithIdentifier:nil
											   previewProvider:nil
												actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
		UIAction *edit = [UIAction actionWithTitle:@"Edit"
										 image:nil
								  identifier:nil
									 handler:^(__kindof UIAction *action) {
			[self editProfile:specifier];
		}];
		UIAction *delete = [UIAction actionWithTitle:@"Delete"
										   image:nil
									identifier:nil
									 handler:^(__kindof UIAction *action) {
			[PSNRootListController deleteProfileAtIndex:index];
			[self reloadSpecifiers];
		}];
		delete.attributes = UIMenuElementAttributesDestructive;
		return [UIMenu menuWithTitle:@"" children:@[edit, delete]];
	}];
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
	if (section != [self numberOfGroups] - 1) { return nil; }

	CGFloat width = tableView.bounds.size.width;
	if (width < 1) { width = CGRectGetWidth([[UIScreen mainScreen] bounds]); }

	UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 72)];

	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	NSDictionary *info = bundle.infoDictionary;
	NSString *version = info[@"CFBundleShortVersionString"] ?: @"0.1-dev";
	NSString *build = info[@"CFBundleVersion"] ?: @"0";
	NSString *labelText = [NSString stringWithFormat:@"ProxySwitcher-ng %@ (build %@)", version, build];

	UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, width - 32, 20)];
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	label.textColor = [UIColor secondaryLabelColor];
	label.text = labelText;
	[container addSubview:label];

	UIButton *github = [self iconButtonNamed:@"github" URLString:@"https://github.com/ymuuuu"];
	github.frame = CGRectMake(16, 36, 24, 24);
	[container addSubview:github];

	UIButton *website = [self iconButtonNamed:@"website" URLString:@"https://ymuu.me"];
	website.frame = CGRectMake(48, 36, 24, 24);
	[container addSubview:website];

	return container;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
	if (section == [self numberOfGroups] - 1) { return 72; }
	return UITableViewAutomaticDimension;
}

- (UIButton *)iconButtonNamed:(NSString *)name URLString:(NSString *)URLString {
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	UIImage *image = [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil];
	if (image) {
		image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	}
	UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
	[button setImage:image forState:UIControlStateNormal];
	button.tintColor = [UIColor secondaryLabelColor];
	[button addTarget:self action:@selector(openLink:) forControlEvents:UIControlEventTouchUpInside];
	objc_setAssociatedObject(button, &kLinkURLKey, URLString, OBJC_ASSOCIATION_COPY_NONATOMIC);
	return button;
}

- (void)openLink:(UIButton *)sender {
	NSString *URLString = objc_getAssociatedObject(sender, &kLinkURLKey);
	NSURL *url = [NSURL URLWithString:URLString];
	if (url) {
		[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
	}
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Apply"
																	  style:UIBarButtonItemStylePlain
																	 target:self
																	 action:@selector(applyAndVerify:)];
	self.navigationItem.rightBarButtonItem.enabled = [PSNRootListController isEnabled];

	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
									(__bridge void *)self,
									PSApplyButtonStateChanged,
									(__bridge CFStringRef)kSettingsChangedNotification,
									NULL,
									CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	self.navigationItem.rightBarButtonItem.enabled = [PSNRootListController isEnabled];
}

- (void)dealloc {
	CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
									  (__bridge void *)self,
									  (__bridge CFStringRef)kSettingsChangedNotification,
									  NULL);
}

@end
