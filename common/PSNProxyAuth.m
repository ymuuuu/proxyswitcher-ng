#import "PSNProxyAuth.h"

NSString *PSNBase64(NSData *data) {
    return [data base64EncodedStringWithOptions:0] ?: @"";
}

NSString *PSNBasicAuthHeaderLine(NSString *user, NSString *pass) {
    if (user.length == 0) { return @""; }
    NSString *creds = [NSString stringWithFormat:@"%@:%@", user, pass ?: @""];
    NSData *raw = [creds dataUsingEncoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"Proxy-Authorization: Basic %@\r\n", PSNBase64(raw)];
}

NSData *PSNSocks5UserPassRequest(NSString *user, NSString *pass) {
    NSData *u = [(user ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    NSData *p = [(pass ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (u.length > 255 || p.length > 255) { return nil; }
    NSMutableData *out = [NSMutableData data];
    uint8_t ver = 0x01;
    uint8_t ulen = (uint8_t)u.length;
    uint8_t plen = (uint8_t)p.length;
    [out appendBytes:&ver length:1];
    [out appendBytes:&ulen length:1];
    [out appendData:u];
    [out appendBytes:&plen length:1];
    [out appendData:p];
    return out;
}

BOOL PSNSocks5UserPassReplyOK(const uint8_t *reply, size_t len) {
    return (len >= 2 && reply[0] == 0x01 && reply[1] == 0x00);
}
