#import "MBRootListController.h"
#import "MBProfileEditController.h"
#import "MBLogsController.h"
#import <CoreFoundation/CoreFoundation.h>
#import <Preferences/Preferences.h>
#import <UIKit/UIKit.h>

static NSString * const kPrefsDomain = @"io.ymuu.proxyswitcherng";
static NSString * const kSettingsChangedNotification = @"io.ymuu.proxyswitcherng/settingschanged";

static NSString * const kProfileKey = @"isProfile";
static NSString * const kManualKey = @"isManual";
static NSString * const kProfileValueKey = @"profileValue";
static NSString * const kProfileIndexKey = @"profileIndex";

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

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
		if (!_specifiers) {
			_specifiers = [NSMutableArray array];
		}

		NSArray *profiles = [MBRootListController readProfiles];
		[_specifiers addObjectsFromArray:[self profileSpecifiersForProfiles:profiles]];
		[_specifiers addObjectsFromArray:[self aboutSpecifiers]];
	}

	return _specifiers;
}

- (NSArray *)aboutSpecifiers {
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	NSDictionary *info = bundle.infoDictionary;
	NSString *version = info[@"CFBundleShortVersionString"] ?: @"0.1-dev";
	NSString *build = info[@"CFBundleVersion"] ?: @"0";
	NSString *footer = [NSString stringWithFormat:@"ProxySwitcher-ng %@ (build %@)", version, build];

	PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"About"];
	[group setProperty:footer forKey:PSFooterTextGroupKey];
	return @[group];
}

- (NSArray *)profileSpecifiersForProfiles:(NSArray *)profiles {
	NSMutableArray *specifiers = [NSMutableArray array];

	PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"Profiles"];
	[group setProperty:@"Selected profile overrides manual Server/Port." forKey:PSFooterTextGroupKey];
	[specifiers addObject:group];

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

	PSSpecifier *add = [PSSpecifier preferenceSpecifierNamed:@"Add Profile…"
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
	[MBRootListController postSettingsChanged];

	NSURL *url = [NSURL URLWithString:@"http://captive.apple.com/hotspot-detect.html"];
	NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5.0];
	NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
	config.timeoutIntervalForRequest = 5.0;
	NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

	NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			NSString *title = @"Applied";
			NSString *message = nil;
			if (error) {
				message = [NSString stringWithFormat:@"Proxy applied — not reachable ✗\n%@", error.localizedDescription];
			} else {
				NSInteger status = 0;
				if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
					status = ((NSHTTPURLResponse *)response).statusCode;
				}
				NSString *body = @"";
				if (data) {
					body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
				}
				if (status == 200 && [body containsString:@"Success"]) {
					message = @"Proxy applied — connected ✓";
				} else {
					message = [NSString stringWithFormat:@"Proxy applied — not reachable ✗\nHTTP %ld", (long)status];
				}
			}
			UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
			[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
			[self presentViewController:alert animated:YES completion:nil];
		});
	}];
	[task resume];
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

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
	PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
	return [[specifier propertyForKey:kProfileKey] boolValue] && ![[specifier propertyForKey:kManualKey] boolValue];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
	return UITableViewCellEditingStyleNone;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
	PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
	if (![[specifier propertyForKey:kProfileKey] boolValue] || [[specifier propertyForKey:kManualKey] boolValue]) {
		return nil;
	}

	NSInteger index = [[specifier propertyForKey:kProfileIndexKey] integerValue];

	UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
																			 title:@"Delete"
																		   handler:^(UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
		[MBRootListController deleteProfileAtIndex:index];
		[self reloadSpecifiers];
		completionHandler(YES);
	}];

	UIContextualAction *editAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
																			 title:@"Edit"
																		   handler:^(UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
		[self editProfile:specifier];
		completionHandler(YES);
	}];

	return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, editAction]];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Apply"
																		  style:UIBarButtonItemStylePlain
																		 target:self
																		 action:@selector(applyAndVerify:)];
}

@end
