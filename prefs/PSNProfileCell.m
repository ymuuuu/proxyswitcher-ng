#import "PSNProfileCell.h"
#import <Preferences/Preferences.h>

@implementation PSNProfileCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
	self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];
	if (self) {
		self.selectionStyle = UITableViewCellSelectionStyleDefault;
	}
	return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
	[super refreshCellContentsWithSpecifier:specifier];
	self.textLabel.text = [specifier name] ?: @"";
	self.detailTextLabel.text = [specifier propertyForKey:@"psnSubtitle"] ?: @"";
	self.detailTextLabel.font = [UIFont systemFontOfSize:12];
	self.detailTextLabel.textColor = [UIColor secondaryLabelColor];
	self.detailTextLabel.numberOfLines = 1;
}

@end
