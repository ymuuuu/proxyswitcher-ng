#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PSNProxyKind) { PSNProxyKindHTTP, PSNProxyKindSOCKS };

@interface PSNCredential : NSObject
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@end

@interface PSNCredentialStore : NSObject
+ (BOOL)upsertHost:(NSString *)host port:(int)port kind:(PSNProxyKind)kind
          username:(NSString *)user password:(NSString *)pass;
+ (PSNCredential *)lookupHost:(NSString *)host port:(int)port kind:(PSNProxyKind)kind; // nil if absent
+ (BOOL)deleteHost:(NSString *)host port:(int)port kind:(PSNProxyKind)kind;
@end
