#import <Preferences/PSListController.h>

@interface MBRootListController : PSListController

+ (NSArray *)readProfiles;
+ (void)writeProfiles:(NSArray *)profiles;

+ (NSString *)activeProxy;
+ (void)setActiveProxy:(NSString *)activeProxy;
+ (void)postSettingsChanged;

+ (void)addOrUpdateProfile:(NSDictionary *)profile atIndex:(NSInteger)index;
+ (void)deleteProfileAtIndex:(NSInteger)index;

@end
