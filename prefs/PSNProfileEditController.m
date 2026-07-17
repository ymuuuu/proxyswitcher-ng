#import "PSNProfileEditController.h"
#import "PSNRootListController.h"
#import "PSNCredentialClient.h"
#import <Preferences/Preferences.h>
#import <UIKit/UIKit.h>

static NSString * const kProfileEditNameKey = @"name";
static NSString * const kProfileEditHostKey = @"host";
static NSString * const kProfileEditPortKey = @"port";
static NSString * const kProfileEditTypeKey = @"type";
static NSString * const kProfileEditUserKey = @"username";
static NSString * const kProfileEditPassKey = @"password";
static NSString * const kProfileEditAuthKey = @"authOn";

@interface PSNProfileEditController ()
@property (nonatomic, copy) NSString *nameValue;
@property (nonatomic, copy) NSString *hostValue;
@property (nonatomic, copy) NSString *portValue;
@property (nonatomic, copy) NSString *typeValue;
@property (nonatomic, copy) NSString *userValue;
@property (nonatomic, copy) NSString *passValue;
@property (nonatomic) BOOL authOn;
@property (nonatomic, strong) PSSpecifier *authToggleSpec;
@property (nonatomic, strong) PSSpecifier *userSpec;
@property (nonatomic, strong) PSSpecifier *passSpec;
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
		self.userValue = @"";
		self.passValue = @"";
		self.authOn = [self.profile[@"hasAuth"] boolValue];
		// Prefill username from the daemon for an existing profile with auth.
		if (self.authOn) {
			NSString *u = nil, *p = nil;
			BOOL socks = [self.typeValue isEqualToString:@"socks"];
			if ([PSNCredentialClient getHost:self.hostValue port:[self.portValue intValue]
									   socks:socks username:&u password:&p]) {
				self.userValue = u ?: @"";
			}
		}

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

		PSSpecifier *authGroup = [PSSpecifier groupSpecifierWithName:@"Authentication (optional)"];
		[authGroup setProperty:@"Leave blank for no proxy auth. Password is stored in the keychain, never in prefs." forKey:PSFooterTextGroupKey];

		PSSpecifier *authToggleSpec = [PSSpecifier preferenceSpecifierNamed:@"Use authentication"
																   target:self
																	set:@selector(setPreferenceValue:specifier:)
																	get:@selector(readPreferenceValue:)
																   detail:NULL
																	cell:PSSwitchCell
																	edit:NULL];
		[authToggleSpec setProperty:kProfileEditAuthKey forKey:PSKeyNameKey];
		[authToggleSpec setProperty:@(self.authOn) forKey:PSDefaultValueKey];
		self.authToggleSpec = authToggleSpec;

		PSSpecifier *userSpec = [PSSpecifier preferenceSpecifierNamed:@"Username"
				target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
				detail:NULL cell:PSEditTextCell edit:NULL];
		[userSpec setProperty:kProfileEditUserKey forKey:PSKeyNameKey];
		[userSpec setProperty:self.userValue forKey:PSDefaultValueKey];
		self.userSpec = userSpec;

		PSSpecifier *passSpec = [PSSpecifier preferenceSpecifierNamed:@"Password"
				target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
				detail:NULL cell:PSSecureEditTextCell edit:NULL];
		[passSpec setProperty:kProfileEditPassKey forKey:PSKeyNameKey];
		[passSpec setProperty:self.passValue forKey:PSDefaultValueKey];
		self.passSpec = passSpec;

		NSMutableArray *specs = [NSMutableArray arrayWithObjects:group, nameSpec, hostSpec, portSpec, typeSpec,
			authGroup, authToggleSpec, nil];
		if (self.authOn) {
			[specs addObject:userSpec];
			[specs addObject:passSpec];
		}
		_specifiers = specs;
	}

	return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
	NSString *key = [specifier propertyForKey:PSKeyNameKey];
	if ([key isEqualToString:kProfileEditNameKey]) { return self.nameValue ?: @""; }
	if ([key isEqualToString:kProfileEditHostKey]) { return self.hostValue ?: @""; }
	if ([key isEqualToString:kProfileEditPortKey]) { return self.portValue ?: @""; }
	if ([key isEqualToString:kProfileEditTypeKey]) { return @([self.typeValue isEqualToString:@"socks"]); }
	if ([key isEqualToString:kProfileEditAuthKey]) { return @(self.authOn); }
	if ([key isEqualToString:kProfileEditUserKey]) { return self.userValue ?: @""; }
	if ([key isEqualToString:kProfileEditPassKey]) { return self.passValue ?: @""; }
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
	} else if ([key isEqualToString:kProfileEditAuthKey]) {
		BOOL newOn = [value boolValue];
		if (newOn == self.authOn) { return; }
		self.authOn = newOn;
		if (self.authOn) {
			if ([_specifiers indexOfObjectIdenticalTo:self.userSpec] == NSNotFound) {
				[self insertSpecifier:self.userSpec afterSpecifier:self.authToggleSpec animated:YES];
			}
			if ([_specifiers indexOfObjectIdenticalTo:self.passSpec] == NSNotFound) {
				[self insertSpecifier:self.passSpec afterSpecifier:self.userSpec animated:YES];
			}
		} else {
			if ([_specifiers indexOfObjectIdenticalTo:self.userSpec] != NSNotFound) {
				[self removeSpecifier:self.userSpec animated:YES];
			}
			if ([_specifiers indexOfObjectIdenticalTo:self.passSpec] != NSNotFound) {
				[self removeSpecifier:self.passSpec animated:YES];
			}
			self.userValue = @"";
			self.passValue = @"";
		}
	} else if ([key isEqualToString:kProfileEditUserKey]) {
		self.userValue = string;
	} else if ([key isEqualToString:kProfileEditPassKey]) {
		self.passValue = string;
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

	NSString *user = [self.userValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSString *pass = self.passValue ?: @"";
	BOOL socks = [type isEqualToString:@"socks"];
	BOOL hasAuth = (self.authOn && user.length > 0);
	NSMutableDictionary *profile = [@{@"name": name, @"value": value, @"type": type} mutableCopy];
	profile[@"hasAuth"] = @(hasAuth);

	if (hasAuth) {
		// The password field is intentionally blank on reload. If the user did not
		// re-type a password, preserve the one already in the keychain rather than
		// overwriting it with an empty string (e.g. when only the name is changed).
		if (pass.length == 0) {
			NSString *eu = nil, *ep = nil;
			if ([PSNCredentialClient getHost:host port:port socks:socks username:&eu password:&ep] && ep.length > 0) {
				pass = ep;
			}
		}
		[PSNCredentialClient setHost:host port:port socks:socks username:user password:pass];
	} else {
		[PSNCredentialClient deleteHost:host port:port socks:socks];
	}
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
