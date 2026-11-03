#import "PSNPasswordPlaceholder.h"

NSString * const PSNSavedPasswordPlaceholder = @"••••••••";

// The cell's text field is not public API, so find it in the view tree.
static UITextField *PSNFindTextField(UIView *view) {
	if ([view isKindOfClass:[UITextField class]]) { return (UITextField *)view; }
	for (UIView *sub in view.subviews) {
		UITextField *found = PSNFindTextField(sub);
		if (found) { return found; }
	}
	return nil;
}

void PSNSetPasswordPlaceholder(UITableViewCell *cell, NSString *placeholder) {
	PSNFindTextField(cell).placeholder = placeholder;
}
