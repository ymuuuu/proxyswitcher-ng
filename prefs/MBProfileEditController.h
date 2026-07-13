#import <Preferences/PSListController.h>

@interface MBProfileEditController : PSListController

@property (nonatomic, assign) NSInteger profileIndex;
@property (nonatomic, copy) NSDictionary *profile;

@end
