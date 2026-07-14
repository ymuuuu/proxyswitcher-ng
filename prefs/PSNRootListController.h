#import <Preferences/PSListController.h>

@interface PSNRootListController : PSListController

+ (NSArray *)readProfiles;
+ (void)writeProfiles:(NSArray *)profiles;

+ (NSString *)activeProxy;
+ (void)setActiveProxy:(NSString *)activeProxy;
+ (BOOL)isEnabled;
+ (void)postSettingsChanged;

+ (void)addOrUpdateProfile:(NSDictionary *)profile atIndex:(NSInteger)index;
+ (void)deleteProfileAtIndex:(NSInteger)index;

@end
