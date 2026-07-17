#import "PSNProxyRelay.h"
#import "PSNSocketUtil.h"
#import "PSNProxyAuth.h"
#import <sys/socket.h>
#import <sys/select.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdint.h>

const int kPSNRelayPort = 8899;

// PSLog is defined in PSNWiFiProxyHandler.m; declare a lightweight logger here.
#define RLog(fmt, ...) NSLog((fmt), ##__VA_ARGS__)

@interface PSNProxyRelay () {
    int _listenFd;
    dispatch_queue_t _acceptQ;
    NSLock *_cfgLock;
    NSString *_uHost; int _uPort; BOOL _uSocks; NSString *_uUser; NSString *_uPass;
    BOOL _haveCfg;
}
@end

@implementation PSNProxyRelay

+ (instancetype)sharedInstance {
    static PSNProxyRelay *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PSNProxyRelay new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFd = -1;
        _cfgLock = [NSLock new];
        _acceptQ = dispatch_queue_create("io.ymuu.proxyswitcherngd.relay", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)configureUpstreamHost:(NSString *)host port:(int)port socks:(BOOL)socks
                     username:(NSString *)user password:(NSString *)pass {
    [_cfgLock lock];
    _uHost = [host copy]; _uPort = port; _uSocks = socks;
    _uUser = [user copy]; _uPass = [pass copy];
    _haveCfg = (user.length > 0);
    [_cfgLock unlock];
    RLog(@"[relay] configured upstream %@:%d socks=%d auth=%d", host, port, socks, (int)(user.length > 0));
}

- (void)clearUpstream {
    [_cfgLock lock]; _haveCfg = NO; [_cfgLock unlock];
}

- (void)startIfNeeded {
    if (_listenFd >= 0) { return; }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { RLog(@"[relay] socket() failed: %s", strerror(errno)); return; }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)kPSNRelayPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 127.0.0.1 ONLY
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        RLog(@"[relay] bind 127.0.0.1:%d failed: %s", kPSNRelayPort, strerror(errno));
        close(fd); return;
    }
    if (listen(fd, 16) != 0) {
        RLog(@"[relay] listen failed: %s", strerror(errno));
        close(fd); return;
    }
    _listenFd = fd;
    RLog(@"[relay] listening on 127.0.0.1:%d", kPSNRelayPort);
    dispatch_async(_acceptQ, ^{ [self acceptLoop]; });
}

- (void)acceptLoop {
    for (;;) {
        int cfd = accept(_listenFd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) { continue; }
            RLog(@"[relay] accept failed: %s", strerror(errno));
            break;
        }
        struct timeval io = { .tv_sec = 30, .tv_usec = 0 };
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &io, sizeof(io));
        setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &io, sizeof(io));
        dispatch_async(_acceptQ, ^{ [self handleClient:cfd]; });
    }
}

// Snapshot the active config under lock; returns NO if no auth upstream set.
- (BOOL)snapshotHost:(NSString **)h port:(int *)p socks:(BOOL *)s
                user:(NSString **)u pass:(NSString **)pw {
    [_cfgLock lock];
    BOOL ok = _haveCfg;
    if (ok) { *h = _uHost; *p = _uPort; *s = _uSocks; *u = _uUser; *pw = _uPass; }
    [_cfgLock unlock];
    return ok;
}

- (void)handleClient:(int)cfd {
    NSString *host = nil, *user = nil, *pass = nil; int port = 0; BOOL socks = NO;
    if (![self snapshotHost:&host port:&port socks:&socks user:&user pass:&pass]) {
        RLog(@"[relay] no auth upstream configured; closing client");
        close(cfd); return;
    }
    NSString *detail = nil;
    int ufd = PSNConnectWithTimeout(host, port, 10.0, &detail);
    if (ufd < 0) {
        RLog(@"[relay] upstream connect failed: %@", detail);
        close(cfd); return;
    }
    struct timeval io = { .tv_sec = 30, .tv_usec = 0 };
    setsockopt(ufd, SOL_SOCKET, SO_RCVTIMEO, &io, sizeof(io));
    setsockopt(ufd, SOL_SOCKET, SO_SNDTIMEO, &io, sizeof(io));

    BOOL ready = socks
        ? [self bridgeSocksClient:cfd upstream:ufd user:user pass:pass]
        : [self bridgeHttpClient:cfd upstream:ufd user:user pass:pass];
    if (ready) { [self pumpA:cfd b:ufd]; }
    close(cfd); close(ufd);
}

// Reads the client's request head, authenticates to upstream, and readies the
// tunnel. Returns YES when both sides are ready to be pumped.
- (BOOL)bridgeHttpClient:(int)cfd upstream:(int)ufd user:(NSString *)user pass:(NSString *)pass {
    // Read client request head (up to CRLFCRLF).
    char head[4096]; size_t hlen = 0;
    while (hlen < sizeof(head) - 1) {
        ssize_t n = PSNReadSome(cfd, head + hlen, 1); // read client 1 byte at a time until \r\n\r\n
        if (n <= 0) { RLog(@"[relay] http: client head read failed"); return NO; }
        hlen += (size_t)n;
        if (hlen >= 4 && memcmp(head + hlen - 4, "\r\n\r\n", 4) == 0) { break; }
    }
    head[hlen] = 0;
    NSString *headStr = [NSString stringWithUTF8String:head] ?: @"";
    NSString *authLine = PSNBasicAuthHeaderLine(user, pass);

    if ([headStr hasPrefix:@"CONNECT "]) {
        // Rebuild the CONNECT head with Proxy-Authorization injected before CRLFCRLF.
        NSString *withoutTail = [headStr substringToIndex:headStr.length - 2]; // drop final CRLF
        NSString *upstreamHead = [NSString stringWithFormat:@"%@%@\r\n", withoutTail, authLine];
        const char *ub = upstreamHead.UTF8String;
        if (!PSNWriteAll(ufd, ub, strlen(ub))) { return NO; }
        // Read the upstream CONNECT reply head fully (up to CRLFCRLF), so a
        // fragmented response is not misparsed and no tunnel bytes are consumed.
        char resp[1024]; size_t rlen = 0;
        while (rlen < sizeof(resp) - 1) {
            ssize_t n = PSNReadSome(ufd, resp + rlen, 1);
            if (n <= 0) { RLog(@"[relay] http: no upstream CONNECT reply"); return NO; }
            rlen += (size_t)n;
            if (rlen >= 4 && memcmp(resp + rlen - 4, "\r\n\r\n", 4) == 0) { break; }
        }
        resp[rlen] = 0;
        NSString *r = [NSString stringWithUTF8String:resp] ?: @"";
        NSString *statusLine = [[r componentsSeparatedByString:@"\r\n"] firstObject] ?: r;
        NSArray *parts = [statusLine componentsSeparatedByString:@" "];
        NSInteger code = (parts.count >= 2) ? [parts[1] integerValue] : 0;
        if (code != 200) {
            RLog(@"[relay] http: upstream CONNECT rejected: %@", statusLine);
            const char *fail = "HTTP/1.1 502 Bad Gateway\r\n\r\n";
            PSNWriteAll(cfd, fail, strlen(fail));
            return NO;
        }
        const char *ok = "HTTP/1.1 200 Connection Established\r\n\r\n";
        return PSNWriteAll(cfd, ok, strlen(ok));
    } else {
        // Absolute-URI plain HTTP (best-effort): inject Proxy-Authorization into the head, forward, then splice.
        NSString *withoutTail = [headStr substringToIndex:headStr.length - 2];
        NSString *upstreamHead = [NSString stringWithFormat:@"%@%@\r\n", withoutTail, authLine];
        const char *ub = upstreamHead.UTF8String;
        if (!PSNWriteAll(ufd, ub, strlen(ub))) { return NO; }
        return YES; // pump handles the response + any body/keepalive best-effort
    }
}

- (BOOL)bridgeSocksClient:(int)cfd upstream:(int)ufd user:(NSString *)user pass:(NSString *)pass {
    // 1) Client greeting: VER NMETHODS METHODS... ; reply no-auth.
    uint8_t g[2];
    if (PSNReadSome(cfd, g, 2) < 2 || g[0] != 0x05) { return NO; }
    uint8_t nmethods = g[1];
    uint8_t methods[255];
    if (nmethods > 0 && PSNReadSome(cfd, methods, nmethods) < nmethods) { return NO; }
    uint8_t noAuth[2] = {0x05, 0x00};
    if (!PSNWriteAll(cfd, noAuth, 2)) { return NO; }

    // 2) Read the client CONNECT request head (VER CMD RSV ATYP ...). Keep raw to forward.
    uint8_t req[262]; ssize_t rn = PSNReadSome(cfd, req, 4);
    if (rn < 4 || req[0] != 0x05) { return NO; }
    size_t need = 0;
    if (req[3] == 0x01) { need = 4 + 2; }            // IPv4 + port
    else if (req[3] == 0x03) {                        // domain
        uint8_t dlen; if (PSNReadSome(cfd, &dlen, 1) < 1) { return NO; }
        req[4] = dlen; if (PSNReadSome(cfd, req + 5, dlen + 2) < dlen + 2) { return NO; }
        rn = 5 + dlen + 2; goto haveReq;
    } else if (req[3] == 0x04) { need = 16 + 2; }     // IPv6 + port
    else { return NO; }
    if (PSNReadSome(cfd, req + 4, need) < (ssize_t)need) { return NO; }
    rn = 4 + need;
haveReq: ;

    // 3) Upstream: greeting offering user/pass (0x02).
    uint8_t ug[3] = {0x05, 0x01, 0x02};
    if (!PSNWriteAll(ufd, ug, 3)) { return NO; }
    uint8_t um[2];
    if (PSNReadSome(ufd, um, 2) < 2 || um[0] != 0x05) { return NO; }
    if (um[1] != 0x02) {
        RLog(@"[relay] socks: upstream did not accept user/pass (method=0x%02x)", um[1]);
        return NO;
    }
    // 4) RFC 1929 sub-negotiation.
    NSData *auth = PSNSocks5UserPassRequest(user, pass);
    if (!auth || !PSNWriteAll(ufd, auth.bytes, auth.length)) { return NO; }
    uint8_t ar[2];
    if (PSNReadSome(ufd, ar, 2) < 2 || !PSNSocks5UserPassReplyOK(ar, 2)) {
        RLog(@"[relay] socks: upstream auth rejected");
        return NO;
    }
    // 5) Forward the client's CONNECT request to upstream, relay the reply back.
    if (!PSNWriteAll(ufd, req, (size_t)rn)) { return NO; }
    uint8_t rep[262]; ssize_t repn = PSNReadSome(ufd, rep, sizeof(rep));
    if (repn < 2) { return NO; }
    if (!PSNWriteAll(cfd, rep, (size_t)repn)) { return NO; }
    return (rep[1] == 0x00);
}

- (void)pumpA:(int)a b:(int)b {
    uint8_t buf[8192];
    for (;;) {
        fd_set rset; FD_ZERO(&rset); FD_SET(a, &rset); FD_SET(b, &rset);
        int maxfd = (a > b ? a : b) + 1;
        struct timeval tv = { .tv_sec = 60, .tv_usec = 0 };
        int sel = select(maxfd, &rset, NULL, NULL, &tv);
        if (sel <= 0) { break; } // timeout or error: tear down
        if (FD_ISSET(a, &rset)) {
            ssize_t n = read(a, buf, sizeof(buf));
            if (n <= 0) { break; }
            if (!PSNWriteAll(b, buf, (size_t)n)) { break; }
        }
        if (FD_ISSET(b, &rset)) {
            ssize_t n = read(b, buf, sizeof(buf));
            if (n <= 0) { break; }
            if (!PSNWriteAll(a, buf, (size_t)n)) { break; }
        }
    }
}

@end
