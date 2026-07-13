#import "MBLogsController.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString * const kLogPath = @"/var/mobile/Library/Logs/ProxySwitcherNG.log";
static NSString * const kClearLogNotification = @"io.ymuu.proxyswitcherng/clearlog";

@interface MBLogsController ()
@property (nonatomic, strong) UITextView *textView;
@end

@implementation MBLogsController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Logs";

	self.view.backgroundColor = [UIColor systemBackgroundColor];

	UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
	textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	textView.editable = NO;
	textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
	[self.view addSubview:textView];
	self.textView = textView;

	self.navigationItem.rightBarButtonItems = @[
		[[UIBarButtonItem alloc] initWithTitle:@"Refresh" style:UIBarButtonItemStylePlain target:self action:@selector(refresh:)],
		[[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStylePlain target:self action:@selector(clear:)]
	];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self refresh:nil];
}

- (void)refresh:(id)sender {
	NSString *text = [NSString stringWithContentsOfFile:kLogPath encoding:NSUTF8StringEncoding error:nil];
	self.textView.text = text.length > 0 ? text : @"(empty)";
	NSRange end = NSMakeRange(self.textView.text.length, 0);
	[self.textView scrollRangeToVisible:end];
}

- (void)clear:(id)sender {
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
										 (__bridge CFStringRef)kClearLogNotification,
										 NULL,
										 NULL,
										 YES);
	self.textView.text = @"(empty)";
}

@end
