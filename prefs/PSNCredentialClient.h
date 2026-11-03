#import <Foundation/Foundation.h>

// Placeholder shown in a Password field when a password is stored. A stored
// password is never read back into the field; a placeholder is never committed,
// so the dots can never be saved as the password.
extern NSString * const PSNSavedPasswordPlaceholder;

@interface PSNCredentialClient : NSObject
// Sends set/delete over the daemon's UNIX-domain credential socket; on socket
// failure falls back to a cfprefs pendingCred blob + settingschanged (the daemon
// drains and purges it).
+ (void)setHost:(NSString *)host port:(int)port socks:(BOOL)socks
       username:(NSString *)user password:(NSString *)pass;
+ (void)deleteHost:(NSString *)host port:(int)port socks:(BOOL)socks;
// Synchronous get for the Apply probe; returns NO if none. Out params empty on miss.
+ (BOOL)getHost:(NSString *)host port:(int)port socks:(BOOL)socks
       username:(NSString **)user password:(NSString **)pass;
@end
