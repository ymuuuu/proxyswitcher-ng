#import <Foundation/Foundation.h>

// Parses "host:port". Splits on the LAST colon so "user:pass@h:1234" works.
// Returns NO and leaves the out-params untouched on any malformed input.
BOOL PSNParseHostPort(NSString *value, NSString **outHost, NSNumber **outPort);
