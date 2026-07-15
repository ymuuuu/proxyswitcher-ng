#import "PSNProfileEditController.h"
#import "PSNRootListController.h"
#import <Preferences/Preferences.h>
#import <UIKit/UIKit.h>

static NSString * const kProfileEditNameKey = @"name";
static NSString * const kProfileEditHostKey = @"host";
static NSString * const kProfileEditPortKey = @"port";
static NSString * const kProfileEditTypeKey = @"type";

@interface PSNProfileEditController ()
@property (nonatomic, copy) NSString *nameValue;
@property (nonatomic, copy) NSString *hostValue;
@property (nonatomic, copy) NSString *portValue;
@property (nonatomic, copy) NSString *typeValue;
@end

@implementation PSNProfileEditController

- (NSArray *)specifiers {
	if (!_specifiers) {
		NSString *name = @"";
		NSString *host = @"";
		NSString *port = @"";
		NSString *type = @"http";

		if ([self.profile isKindOfClass:[NSDictionary class]]) {
			name = self.profile[@"name"] ?: @"";
			NSString *value = self.profile[@"value"] ?: @"";
			NSRange colon = [value rangeOfString:@":" options:NSBackwardsSearch];
			if (colon.location != NSNotFound) {
				host = [[value substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				port = [[value substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			}
			if ([self.profile[@"type"] isEqualToString:@"socks"]) { type = @"socks"; }
		}

		self.nameValue = name;
		self.hostValue = host;
		self.portValue = port;
		self.typeValue = type;

		PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"Edit Profile"];

		PSSpecifier *nameSpec = [PSSpecifier preferenceSpecifierNamed:@"Name"
																target:self
																set:@selector(setPreferenceValue:specifier:)
																get:@selector(readPreferenceValue:)
																detail:NULL
																cell:PSEditTextCell
																edit:NULL];
		[nameSpec setProperty:kProfileEditNameKey forKey:PSKeyNameKey];
		[nameSpec setProperty:self.nameValue forKey:PSDefaultValueKey];

		PSSpecifier *hostSpec = [PSSpecifier preferenceSpecifierNamed:@"Host"
																target:self
																set:@selector(setPreferenceValue:specifier:)
																get:@selector(readPreferenceValue:)
																detail:NULL
																cell:PSEditTextCell
																edit:NULL];
		[hostSpec setProperty:kProfileEditHostKey forKey:PSKeyNameKey];
		[hostSpec setProperty:self.hostValue forKey:PSDefaultValueKey];
		[hostSpec setProperty:@(YES) forKey:PSURLKeyboardKey];

		PSSpecifier *portSpec = [PSSpecifier preferenceSpecifierNamed:@"Port"
																target:self
																set:@selector(setPreferenceValue:specifier:)
																get:@selector(readPreferenceValue:)
																detail:NULL
																cell:PSEditTextCell
																edit:NULL];
		[portSpec setProperty:kProfileEditPortKey forKey:PSKeyNameKey];
		[portSpec setProperty:self.portValue forKey:PSDefaultValueKey];
		[portSpec setProperty:@(YES) forKey:PSNumberKeyboardKey];
		[portSpec setProperty:@"NumberPad" forKey:PSKeyboardTypeKey];

		// Plain switch: on = SOCKS, off = HTTP/HTTPS. Both PSLinkListCell (drills
		// into a PSListItemsController that aborts on a hand-built specifier) and
		// PSSegmentCell (renders blank) fail in this Preferences build; a
		// PSSwitchCell is the same cell the Enabled/logging rows use and renders
		// reliably. The get/set map the switch bool to the "http"/"socks" string.
		PSSpecifier *typeSpec = [PSSpecifier preferenceSpecifierNamed:@"Use SOCKS proxy"
																target:self
																set:@selector(setPreferenceValue:specifier:)
																get:@selector(readPreferenceValue:)
																detail:NULL
																cell:PSSwitchCell
																edit:NULL];
		[typeSpec setProperty:kProfileEditTypeKey forKey:PSKeyNameKey];
		[typeSpec setProperty:@([self.typeValue isEqualToString:@"socks"]) forKey:PSDefaultValueKey];

		_specifiers = [NSMutableArray arrayWithObjects:group, nameSpec, hostSpec, portSpec, typeSpec, nil];
	}

	return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
	NSString *key = [specifier propertyForKey:PSKeyNameKey];
	if ([key isEqualToString:kProfileEditNameKey]) { return self.nameValue ?: @""; }
	if ([key isEqualToString:kProfileEditHostKey]) { return self.hostValue ?: @""; }
	if ([key isEqualToString:kProfileEditPortKey]) { return self.portValue ?: @""; }
	if ([key isEqualToString:kProfileEditTypeKey]) { return @([self.typeValue isEqualToString:@"socks"]); }
	return nil;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	NSString *key = [specifier propertyForKey:PSKeyNameKey];
	NSString *string = @"";
	if ([value isKindOfClass:[NSString class]]) {
		string = value;
	} else if (value) {
		string = [value description];
	}

	if ([key isEqualToString:kProfileEditNameKey]) {
		self.nameValue = string;
	} else if ([key isEqualToString:kProfileEditHostKey]) {
		self.hostValue = string;
	} else if ([key isEqualToString:kProfileEditPortKey]) {
		self.portValue = string;
	} else if ([key isEqualToString:kProfileEditTypeKey]) {
		self.typeValue = [value boolValue] ? @"socks" : @"http";
	}
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
																										 target:self
																										 action:@selector(saveProfile:)];
}

- (void)saveProfile:(id)sender {
	[self.view endEditing:YES];

	NSString *host = [self.hostValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSString *portStr = [self.portValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	if (host.length == 0) {
		[self showAlertWithTitle:@"Invalid Host" message:@"Host cannot be empty."];
		return;
	}

	NSScanner *scanner = [NSScanner scannerWithString:portStr];
	int port = 0;
	if (![scanner scanInt:&port] || port < 1 || port > 65535 || ![scanner isAtEnd]) {
		[self showAlertWithTitle:@"Invalid Port" message:@"Port must be an integer between 1 and 65535."];
		return;
	}

	NSString *name = [self.nameValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (name.length == 0) {
		name = host;
	}
	NSString *value = [NSString stringWithFormat:@"%@:%d", host, port];
	NSString *type = [self.typeValue isEqualToString:@"socks"] ? @"socks" : @"http";
	NSDictionary *profile = @{@"name": name, @"value": value, @"type": type};

	[PSNRootListController addOrUpdateProfile:profile atIndex:self.profileIndex];

	[self.navigationController popViewControllerAnimated:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	if ([self.parentController respondsToSelector:@selector(reloadSpecifiers)]) {
		[(PSListController *)self.parentController reloadSpecifiers];
	}
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
																	 message:message
														  preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end
