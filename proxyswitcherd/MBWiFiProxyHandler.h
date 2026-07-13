#import <Foundation/Foundation.h>

@interface MBWiFiProxyHandler : NSObject

+ (instancetype)sharedInstance;
- (void)applyFromPreferences;

@end
