#import <Foundation/Foundation.h>

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
