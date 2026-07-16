#import "PSNCredIPC.h"
#import "PSNSocketUtil.h"
#import <stdint.h>

// Credential payloads are tiny (a host, port, and short user/pass); cap the
// frame so a malformed length can never make us allocate unboundedly.
static const uint32_t kPSNCredMaxFrame = 64 * 1024;

NSData *PSNCredFrameRead(int fd) {
    uint8_t lenbuf[4];
    if (PSNReadSome(fd, lenbuf, 4) < 4) { return nil; }
    uint32_t len = ((uint32_t)lenbuf[0] << 24) | ((uint32_t)lenbuf[1] << 16) |
                   ((uint32_t)lenbuf[2] << 8)  |  (uint32_t)lenbuf[3];
    if (len == 0 || len > kPSNCredMaxFrame) { return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:len];
    if (PSNReadSome(fd, data.mutableBytes, len) < (ssize_t)len) { return nil; }
    return data;
}

BOOL PSNCredFrameWrite(int fd, NSData *payload) {
    uint32_t len = (uint32_t)payload.length;
    uint8_t lenbuf[4] = { (uint8_t)(len >> 24), (uint8_t)(len >> 16),
                          (uint8_t)(len >> 8),  (uint8_t)len };
    if (!PSNWriteAll(fd, lenbuf, 4)) { return NO; }
    return PSNWriteAll(fd, payload.bytes, payload.length);
}
