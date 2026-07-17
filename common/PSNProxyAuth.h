#import <Foundation/Foundation.h>
#import <stdint.h>

NSString *PSNBase64(NSData *data);
NSString *PSNBasicAuthHeaderLine(NSString *user, NSString *pass);
NSData *PSNSocks5UserPassRequest(NSString *user, NSString *pass);
BOOL PSNSocks5UserPassReplyOK(const uint8_t *reply, size_t len);
