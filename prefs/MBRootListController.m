#import "MBRootListController.h"
#import "MBProfileEditController.h"
#import "MBLogsController.h"
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

static NSString * const kPrefsDomain = @"io.ymuu.proxyswitcherng";
static NSString * const kSettingsChangedNotification = @"io.ymuu.proxyswitcherng/settingschanged";
static NSString * const kNoneToken = @"__none__";

static NSString * const kProfileKey = @"isProfile";
static NSString * const kManualKey = @"isManual";
static NSString * const kProfileValueKey = @"profileValue";
static NSString * const kProfileIndexKey = @"profileIndex";

static char kLinkURLKey;

static void PSApplyButtonStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	MBRootListController *controller = (__bridge MBRootListController *)observer;
	dispatch_async(dispatch_get_main_queue(), ^{
		controller.navigationItem.rightBarButtonItem.enabled = [MBRootListController isEnabled];
	});
}

typedef NS_ENUM(NSInteger, PSProbeResult) {
	PSProbeConnected = 0,
	PSProbeRefused,
	PSProbeTimeout,
	PSProbeDNSFail,
};

// Raw TCP connect to host:port with a timeout. This actually exercises the
// proxy endpoint (does something accept a connection there?), which is the real
// question item 3 asks. An earlier NSURLSession probe against an https URL gave
// false positives: when the proxy was down, the session silently fell back to a
// direct connection to the test site and reported success.
static PSProbeResult PSProbeProxy(NSString *host, int port, NSTimeInterval timeout) {
	struct addrinfo hints;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;

	char portStr[16];
	snprintf(portStr, sizeof(portStr), "%d", port);

	struct addrinfo *res = NULL;
	if (getaddrinfo(host.UTF8String, portStr, &hints, &res) != 0 || res == NULL) {
		return PSProbeDNSFail;
	}

	PSProbeResult result = PSProbeRefused;
	for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
		int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
		if (fd < 0) { continue; }

		int flags = fcntl(fd, F_GETFL, 0);
		fcntl(fd, F_SETFL, flags | O_NONBLOCK);

		int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
		if (rc == 0) {
			close(fd);
			result = PSProbeConnected;
			break;
		}
		if (errno != EINPROGRESS) {
			close(fd);
			result = PSProbeRefused;
			continue;
		}

		fd_set wset;
		FD_ZERO(&wset);
		FD_SET(fd, &wset);
		struct timeval tv;
		tv.tv_sec = (long)timeout;
		tv.tv_usec = (long)((timeout - (long)timeout) * 1000000);

		int sel = select(fd + 1, NULL, &wset, NULL, &tv);
		if (sel == 0) {
			close(fd);
			result = PSProbeTimeout;
			continue;
		}
		if (sel < 0) {
			close(fd);
			result = PSProbeRefused;
			continue;
		}

		int soErr = 0;
		socklen_t len = sizeof(soErr);
		if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) < 0 || soErr != 0) {
			close(fd);
			result = PSProbeRefused;
			continue;
		}

		close(fd);
		result = PSProbeConnected;
		break;
	}

	freeaddrinfo(res);
	return result;
}

@interface MBRootListController ()

+ (BOOL)parseHostPort:(NSString *)value host:(NSString **)outHost port:(NSNumber **)outPort;

- (UIButton *)iconButtonNamed:(NSString *)name URLString:(NSString *)URLString;
- (void)openLink:(UIButton *)sender;

@end

@implementation MBRootListController

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

		NSArray *profiles = [MBRootListController readProfiles];
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
		if ([profile isKindOfClass:[NSDictionary class]]) {
			name = profile[@"name"] ?: @"";
			value = profile[@"value"] ?: @"";
		}
		if (name.length == 0) { name = value; }
		if (name.length == 0) { name = @"(untitled)"; }

		NSString *title = [NSString stringWithFormat:@"%@ (%@)", name, value];
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
	[MBRootListController setActiveProxy:value];
	[MBRootListController postSettingsChanged];
	[self reloadSpecifiers];
}

- (void)addProfile:(PSSpecifier *)specifier {
	MBProfileEditController *editController = [[MBProfileEditController alloc] init];
	editController.profileIndex = -1;
	editController.profile = nil;
	[self pushController:editController];
}

- (void)editProfile:(PSSpecifier *)specifier {
	NSInteger index = [[specifier propertyForKey:kProfileIndexKey] integerValue];
	NSArray *profiles = [MBRootListController readProfiles];
	if (index < 0 || index >= (NSInteger)profiles.count) { return; }
	NSDictionary *profile = profiles[index];

	MBProfileEditController *editController = [[MBProfileEditController alloc] init];
	editController.profileIndex = index;
	editController.profile = profile;
	[self pushController:editController];
}

- (void)openLogs:(PSSpecifier *)specifier {
	MBLogsController *logsController = [[MBLogsController alloc] init];
	[self pushController:logsController];
}

- (void)applyAndVerify:(id)sender {
	if (![MBRootListController isEnabled]) {
		[MBRootListController postSettingsChanged];
		return;
	}

	[MBRootListController postSettingsChanged];

	NSString *activeProxy = [MBRootListController activeProxy] ?: @"";
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

	if ([MBRootListController parseHostPort:activeProxy host:&testHost port:&testPort]) {
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

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		PSProbeResult probe = PSProbeProxy(hostCopy, portInt, 8.0);
		dispatch_async(dispatch_get_main_queue(), ^{
			NSString *message = nil;
			switch (probe) {
				case PSProbeConnected:
					message = [NSString stringWithFormat:@"Connected to %@", displayHostPort];
					break;
				case PSProbeRefused:
					message = [NSString stringWithFormat:@"%@ refused the connection. Is the proxy running?", displayHostPort];
					break;
				case PSProbeTimeout:
					message = [NSString stringWithFormat:@"%@ timed out. Not reachable on this network.", displayHostPort];
					break;
				case PSProbeDNSFail:
				default:
					message = [NSString stringWithFormat:@"Could not resolve %@", hostCopy];
					break;
			}
			UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Apply" message:message preferredStyle:UIAlertControllerStyleAlert];
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
		NSString *activeProxy = [MBRootListController activeProxy] ?: @"";
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
			[MBRootListController deleteProfileAtIndex:index];
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
	self.navigationItem.rightBarButtonItem.enabled = [MBRootListController isEnabled];

	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
									(__bridge void *)self,
									PSApplyButtonStateChanged,
									(__bridge CFStringRef)kSettingsChangedNotification,
									NULL,
									CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	self.navigationItem.rightBarButtonItem.enabled = [MBRootListController isEnabled];
}

- (void)dealloc {
	CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
									  (__bridge void *)self,
									  (__bridge CFStringRef)kSettingsChangedNotification,
									  NULL);
}

@end
