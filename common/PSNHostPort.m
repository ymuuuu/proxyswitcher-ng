#import "PSNHostPort.h"

BOOL PSNParseHostPort(NSString *value, NSString **outHost, NSNumber **outPort) {
    if (![value isKindOfClass:[NSString class]]) { return NO; }
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *trimmed = [value stringByTrimmingCharactersInSet:ws];
    if (trimmed.length == 0) { return NO; }

    NSRange colon = [trimmed rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location == NSNotFound) { return NO; }

    NSString *host = [[trimmed substringToIndex:colon.location] stringByTrimmingCharactersInSet:ws];
    NSString *portStr = [[trimmed substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:ws];
    if (host.length == 0 || portStr.length == 0) { return NO; }

    NSCharacterSet *digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
    if ([portStr rangeOfCharacterFromSet:[digits invertedSet]].location != NSNotFound) { return NO; }

    NSInteger port = [portStr integerValue];
    if (port < 1 || port > 65535) { return NO; }

    if (outHost) { *outHost = host; }
    if (outPort) { *outPort = @(port); }
    return YES;
}
