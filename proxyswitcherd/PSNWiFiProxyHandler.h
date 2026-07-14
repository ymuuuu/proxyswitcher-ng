#import <Foundation/Foundation.h>

@interface PSNWiFiProxyHandler : NSObject

+ (instancetype)sharedInstance;
- (void)applyFromPreferences;
+ (BOOL)parseHostPort:(NSString *)value host:(NSString **)outHost port:(NSNumber **)outPort;

@end
