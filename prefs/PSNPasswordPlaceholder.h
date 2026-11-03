#import <UIKit/UIKit.h>

// Placeholder shown in a Password field when a password is stored. A stored
// password is never read back into the field; a placeholder is never committed,
// so the dots can never be saved as the password.
extern NSString * const PSNSavedPasswordPlaceholder;

// PSSecureEditTextCell ignores the specifier's placeholder property, so set it
// on the cell's text field directly. Pass nil to clear it.
void PSNSetPasswordPlaceholder(UITableViewCell *cell, NSString *placeholder);
