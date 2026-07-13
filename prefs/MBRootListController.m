#import "MBRootListController.h"
#import "MBProfileEditController.h"
#import <CoreFoundation/CoreFoundation.h>
#import <Preferences/Preferences.h>

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
	}

	return _specifiers;
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

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
	[super setEditing:editing animated:animated];
	[self.tableView setEditing:editing animated:animated];
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
	PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
	if ([[specifier propertyForKey:kProfileKey] boolValue] && tableView.isEditing) {
		[tableView deselectRowAtIndexPath:indexPath animated:YES];
		[self editProfile:specifier];
		return;
	}
	[super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
	PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
	return [[specifier propertyForKey:kProfileKey] boolValue] && ![[specifier propertyForKey:kManualKey] boolValue];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
	PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
	if ([[specifier propertyForKey:kProfileKey] boolValue] && ![[specifier propertyForKey:kManualKey] boolValue]) {
		return UITableViewCellEditingStyleDelete;
	}
	return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (editingStyle != UITableViewCellEditingStyleDelete) { return; }
	PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
	NSInteger index = [[specifier propertyForKey:kProfileIndexKey] integerValue];
	[MBRootListController deleteProfileAtIndex:index];
	[self reloadSpecifiers];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.navigationItem.rightBarButtonItem = self.editButtonItem;
}

@end
