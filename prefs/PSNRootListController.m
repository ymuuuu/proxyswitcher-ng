#import "PSNRootListController.h"
#import "PSNProfileEditController.h"
#import "PSNLogsController.h"
#import <CoreFoundation/CoreFoundation.h>
#import <Preferences/Preferences.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <sys/time.h>
#import <netdb.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
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

// Write every byte; NO on error.
static BOOL PSWriteAll(int fd, const void *buf, size_t len) {
	const uint8_t *p = (const uint8_t *)buf;
	size_t off = 0;
	while (off < len) {
		ssize_t n = write(fd, p + off, len - off);
		if (n > 0) { off += (size_t)n; continue; }
		if (n < 0 && errno == EINTR) { continue; }
		return NO;
	}
	return YES;
}

// Read up to len bytes, stopping on EOF/timeout; returns bytes actually read.
static ssize_t PSReadSome(int fd, void *buf, size_t len) {
	uint8_t *p = (uint8_t *)buf;
	size_t off = 0;
	while (off < len) {
		ssize_t n = read(fd, p + off, len - off);
		if (n > 0) { off += (size_t)n; continue; }
		if (n == 0) { break; }
		if (errno == EINTR) { continue; }
		break; // EAGAIN (SO_RCVTIMEO) or other: return what we have
	}
	return (ssize_t)off;
}

// TCP connect to host:port with a timeout, then switch the socket to blocking
// with SO_RCVTIMEO/SO_SNDTIMEO for the proxy handshake. Returns fd (>=0) or -1,
// setting *detail to a specific reason (DNS, refused, timeout).
static int PSConnectWithTimeout(NSString *host, int port, NSTimeInterval timeout, NSString **detail) {
	struct addrinfo hints;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;

	char portStr[16];
	snprintf(portStr, sizeof(portStr), "%d", port);

	struct addrinfo *res = NULL;
	int gai = getaddrinfo(host.UTF8String, portStr, &hints, &res);
	if (gai != 0 || res == NULL) {
		if (detail) { *detail = [NSString stringWithFormat:@"cannot resolve %@ (%s)", host, gai_strerror(gai)]; }
		return -1;
	}

	int outFd = -1;
	NSString *lastErr = nil;
	for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
		int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
		if (fd < 0) { continue; }

		int flags = fcntl(fd, F_GETFL, 0);
		fcntl(fd, F_SETFL, flags | O_NONBLOCK);

		int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
		if (rc != 0 && errno == EINPROGRESS) {
			fd_set wset;
			FD_ZERO(&wset);
			FD_SET(fd, &wset);
			struct timeval tv;
			tv.tv_sec = (long)timeout;
			tv.tv_usec = (long)((timeout - (long)timeout) * 1000000);
			int sel = select(fd + 1, NULL, &wset, NULL, &tv);
			if (sel == 0) {
				lastErr = [NSString stringWithFormat:@"connect to %@:%d timed out after %.0fs", host, port, timeout];
				close(fd); continue;
			}
			if (sel < 0) {
				lastErr = [NSString stringWithFormat:@"select on %@:%d: %s", host, port, strerror(errno)];
				close(fd); continue;
			}
			int soErr = 0;
			socklen_t l = sizeof(soErr);
			if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &l) < 0 || soErr != 0) {
				lastErr = [NSString stringWithFormat:@"connect to %@:%d: %s", host, port, strerror(soErr ? soErr : errno)];
				close(fd); continue;
			}
		} else if (rc != 0) {
			lastErr = [NSString stringWithFormat:@"connect to %@:%d: %s", host, port, strerror(errno)];
			close(fd); continue;
		}

		fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
		struct timeval io;
		io.tv_sec = (long)timeout;
		io.tv_usec = 0;
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &io, sizeof(io));
		setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &io, sizeof(io));
		outFd = fd;
		break;
	}

	freeaddrinfo(res);
	if (outFd < 0 && detail) { *detail = lastErr ?: @"connection failed"; }
	return outFd;
}

// SOCKS5 no-auth handshake + CONNECT to the target on an already-connected fd.
// Returns YES on a 0x00 reply; *detail always gets a specific reason.
static BOOL PSProbeSocks5(int fd, NSString **detail) {
	uint8_t greet[3] = {0x05, 0x01, 0x00};
	if (!PSWriteAll(fd, greet, sizeof(greet))) {
		if (detail) { *detail = [NSString stringWithFormat:@"SOCKS5 greeting write failed: %s", strerror(errno)]; }
		return NO;
	}
	uint8_t methodResp[2] = {0, 0};
	if (PSReadSome(fd, methodResp, 2) < 2) {
		if (detail) { *detail = @"SOCKS5: no method reply (timeout?)"; }
		return NO;
	}
	if (methodResp[0] != 0x05 || methodResp[1] != 0x00) {
		if (detail) {
			*detail = [NSString stringWithFormat:@"SOCKS5 handshake rejected (ver=0x%02x, method=0x%02x)%@",
				methodResp[0], methodResp[1], methodResp[1] == 0xFF ? @", server requires auth" : @""];
		}
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
	if (!PSWriteAll(fd, req, i)) {
		if (detail) { *detail = [NSString stringWithFormat:@"SOCKS5 CONNECT write failed: %s", strerror(errno)]; }
		return NO;
	}

	uint8_t rep[10] = {0};
	if (PSReadSome(fd, rep, sizeof(rep)) < 2) {
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
static BOOL PSProbeHttpConnect(int fd, NSString **detail) {
	NSString *reqStr = [NSString stringWithFormat:@"CONNECT %@:%d HTTP/1.1\r\nHost: %@:%d\r\n\r\n",
		kProbeTargetHost, kProbeTargetPort, kProbeTargetHost, kProbeTargetPort];
	const char *req = reqStr.UTF8String;
	if (!PSWriteAll(fd, req, strlen(req))) {
		if (detail) { *detail = [NSString stringWithFormat:@"HTTP CONNECT write failed: %s", strerror(errno)]; }
		return NO;
	}

	char buf[256];
	memset(buf, 0, sizeof(buf));
	if (PSReadSome(fd, buf, sizeof(buf) - 1) <= 0) {
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
	if (detail) { *detail = [NSString stringWithFormat:@"HTTP CONNECT failed: %@", statusLine.length ? statusLine : resp]; }
	return NO;
}

// Verify the proxy actually forwards by reaching kProbeTargetHost through it.
// Speaks the proxy protocol on a raw socket (HTTP CONNECT or SOCKS5), so there is
// no NSURLSession direct-fallback false positive. *detail always gets a specific
// reason, success or failure.
static BOOL PSProbeThroughProxy(NSString *proxyHost, int proxyPort, BOOL useSocks, NSTimeInterval timeout, NSString **detail) {
	int fd = PSConnectWithTimeout(proxyHost, proxyPort, timeout, detail);
	if (fd < 0) { return NO; }
	BOOL ok = useSocks ? PSProbeSocks5(fd, detail) : PSProbeHttpConnect(fd, detail);
	close(fd);
	return ok;
}

@interface PSNRootListController ()

+ (BOOL)parseHostPort:(NSString *)value host:(NSString **)outHost port:(NSNumber **)outPort;

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
		NSString *title = [NSString stringWithFormat:@"%@ (%@) - %@", name, value, typeLabel];
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

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSString *detail = nil;
		BOOL ok = PSProbeThroughProxy(hostCopy, portInt, useSocks, 8.0, &detail);
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
