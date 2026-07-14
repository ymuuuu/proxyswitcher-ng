#import <Preferences/PSListController.h>

@interface PSNProfileEditController : PSListController

@property (nonatomic, assign) NSInteger profileIndex;
@property (nonatomic, copy) NSDictionary *profile;

@end
