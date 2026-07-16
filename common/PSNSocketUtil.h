#import <Foundation/Foundation.h>

int PSNConnectWithTimeout(NSString *host, int port, NSTimeInterval timeout, NSString **detail);
BOOL PSNWriteAll(int fd, const void *buf, size_t len);
ssize_t PSNReadSome(int fd, void *buf, size_t len);
