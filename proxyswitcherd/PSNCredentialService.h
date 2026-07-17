#import <Foundation/Foundation.h>

@interface PSNCredentialService : NSObject
+ (void)start;                 // binds the UNIX-domain credential socket + accept loop
+ (void)drainPendingFromPrefs; // cfprefs-purge fallback intake (called on settingschanged)
@end
