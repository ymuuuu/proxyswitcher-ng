#import "PSNSocketUtil.h"
#import <sys/socket.h>
#import <sys/select.h>
#import <sys/time.h>
#import <netdb.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdint.h>

int PSNConnectWithTimeout(NSString *host, int port, NSTimeInterval timeout, NSString **detail) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%d", port);

    struct addrinfo *res = NULL;
    int gai = getaddrinfo(host.UTF8String, portStr, &hints, &res);
    if (gai != 0 || res == NULL) {
        if (detail) { *detail = [NSString stringWithFormat:@"cannot resolve %@ (%s)", host, gai_strerror(gai)]; }
        return -1;
    }

    int outFd = -1;
    NSString *lastErr = nil;
    for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
        int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) { continue; }

        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc != 0 && errno == EINPROGRESS) {
            fd_set wset;
            FD_ZERO(&wset);
            FD_SET(fd, &wset);
            struct timeval tv;
            tv.tv_sec = (long)timeout;
            tv.tv_usec = (long)((timeout - (long)timeout) * 1000000);
            int sel = select(fd + 1, NULL, &wset, NULL, &tv);
            if (sel == 0) {
                lastErr = [NSString stringWithFormat:@"connect to %@:%d timed out after %.0fs", host, port, timeout];
                close(fd); continue;
            }
            if (sel < 0) {
                lastErr = [NSString stringWithFormat:@"select on %@:%d: %s", host, port, strerror(errno)];
                close(fd); continue;
            }
            int soErr = 0;
            socklen_t l = sizeof(soErr);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &l) < 0 || soErr != 0) {
                lastErr = [NSString stringWithFormat:@"connect to %@:%d: %s", host, port, strerror(soErr ? soErr : errno)];
                close(fd); continue;
            }
        } else if (rc != 0) {
            lastErr = [NSString stringWithFormat:@"connect to %@:%d: %s", host, port, strerror(errno)];
            close(fd); continue;
        }

        fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
        struct timeval io;
        io.tv_sec = (long)timeout;
        io.tv_usec = 0;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &io, sizeof(io));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &io, sizeof(io));
        outFd = fd;
        break;
    }

    freeaddrinfo(res);
    if (outFd < 0 && detail) { *detail = lastErr ?: @"connection failed"; }
    return outFd;
}

BOOL PSNWriteAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, p + off, len - off);
        if (n > 0) { off += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) { continue; }
        return NO;
    }
    return YES;
}

ssize_t PSNReadSome(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = read(fd, p + off, len - off);
        if (n > 0) { off += (size_t)n; continue; }
        if (n == 0) { break; }
        if (errno == EINTR) { continue; }
        break;
    }
    return (ssize_t)off;
}
