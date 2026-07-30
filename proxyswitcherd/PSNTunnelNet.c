#include "PSNTunnelNet.h"
#include "PSNNetKernel.h"

#include <sys/socket.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <signal.h>

#pragma mark - address helpers

static void psn_sin(struct sockaddr_in *s, struct in_addr addr) {
    memset(s, 0, sizeof(*s));
    s->sin_len = sizeof(*s);
    s->sin_family = AF_INET;
    s->sin_addr = addr;
}

static void psn_sin_mask(struct sockaddr_in *s, int bits) {
    memset(s, 0, sizeof(*s));
    s->sin_len = sizeof(*s);
    s->sin_family = AF_INET;
    if (bits > 0) {
        s->sin_addr.s_addr = htonl(0xFFFFFFFFu << (32 - bits));
    }
}

static void psn_sin6(struct sockaddr_in6 *s, struct in6_addr addr) {
    memset(s, 0, sizeof(*s));
    s->sin6_len = sizeof(*s);
    s->sin6_family = AF_INET6;
    s->sin6_addr = addr;
}

static void psn_sin6_prefix(struct sockaddr_in6 *s, int bits) {
    memset(s, 0, sizeof(*s));
    s->sin6_len = sizeof(*s);
    s->sin6_family = AF_INET6;
    for (int i = 0; i < 16 && bits > 0; i++, bits -= 8) {
        s->sin6_addr.s6_addr[i] = (bits >= 8) ? 0xff : (uint8_t)(0xff << (8 - bits));
    }
}

#pragma mark - route operations

// One write on a fresh PF_ROUTE socket. No logging: this runs on the signal
// path. Returns false with errno preserved for the caller.
static bool psn_route_write(int rtmType, int addrs, int flags,
                            struct sockaddr *dst, struct sockaddr *gw,
                            struct sockaddr *mask, unsigned ifindex,
                            size_t dstLen, size_t gwLen, size_t maskLen) {
    int rs = socket(PF_ROUTE, SOCK_RAW, dst->sa_family);
    if (rs < 0) { return false; }

    struct { struct rt_msghdr hdr; char payload[512]; } msg;
    memset(&msg, 0, sizeof(msg));

    char *cp = msg.payload;
    memcpy(cp, dst, dstLen); cp += PSN_RT_ROUNDUP(dstLen);
    memcpy(cp, gw, gwLen);   cp += PSN_RT_ROUNDUP(gwLen);
    if (mask) { memcpy(cp, mask, maskLen); cp += PSN_RT_ROUNDUP(maskLen); }

    static int seq = 1;
    msg.hdr.rtm_msglen  = (u_short)(sizeof(struct rt_msghdr) + (cp - msg.payload));
    msg.hdr.rtm_version = RTM_VERSION;
    msg.hdr.rtm_type    = (u_char)rtmType;
    msg.hdr.rtm_index   = (u_short)ifindex;
    msg.hdr.rtm_flags   = flags;
    msg.hdr.rtm_addrs   = addrs;
    msg.hdr.rtm_pid     = getpid();
    msg.hdr.rtm_seq     = seq++;

    bool ok = (write(rs, &msg, msg.hdr.rtm_msglen) >= 0);
    int savedErr = errno;
    close(rs);
    errno = savedErr;
    return ok;
}

static bool psn_route4_once(int rtmType, struct in_addr dst, int maskBits,
                            struct in_addr gw, unsigned ifindex) {
    struct sockaddr_in d, g, m;
    psn_sin(&d, dst);
    psn_sin(&g, gw);

    int addrs = RTA_DST | RTA_GATEWAY;
    int flags = RTF_UP | RTF_GATEWAY | RTF_STATIC;
    struct sockaddr *maskp = NULL;
    size_t maskLen = 0;
    if (maskBits >= 0) {
        psn_sin_mask(&m, maskBits);
        maskp = (struct sockaddr *)&m;
        maskLen = m.sin_len;
        addrs |= RTA_NETMASK;
    } else {
        flags |= RTF_HOST;
    }

    return psn_route_write(rtmType, addrs, flags,
                           (struct sockaddr *)&d, (struct sockaddr *)&g, maskp,
                           ifindex, d.sin_len, g.sin_len, maskLen);
}

bool PSNRoute4Op(bool add, struct in_addr dst, int maskBits,
                 struct in_addr gw, unsigned ifindex, int *errOut) {
    if (errOut) { *errOut = 0; }
    if (add) {
        if (psn_route4_once(RTM_ADD, dst, maskBits, gw, ifindex)) { return true; }
        if (errno == EEXIST) {
            // Stale route from a previous (crashed) daemon: replace it.
            psn_route4_once(RTM_DELETE, dst, maskBits, gw, ifindex);
            if (psn_route4_once(RTM_ADD, dst, maskBits, gw, ifindex)) { return true; }
        }
    } else {
        if (psn_route4_once(RTM_DELETE, dst, maskBits, gw, ifindex)) { return true; }
        if (errno == ESRCH) { return true; }   // already gone: teardown stays idempotent
    }
    if (errOut) { *errOut = errno; }
    return false;
}

static bool psn_route6_once(int rtmType, struct in6_addr dst, int prefixBits,
                            struct in6_addr gw, unsigned ifindex) {
    struct sockaddr_in6 d, g, m;
    psn_sin6(&d, dst);
    psn_sin6(&g, gw);
    psn_sin6_prefix(&m, prefixBits);

    int addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
    int flags = RTF_UP | RTF_GATEWAY | RTF_STATIC;
    return psn_route_write(rtmType, addrs, flags,
                           (struct sockaddr *)&d, (struct sockaddr *)&g,
                           (struct sockaddr *)&m, ifindex,
                           d.sin6_len, g.sin6_len, m.sin6_len);
}

bool PSNRoute6Op(bool add, struct in6_addr dst, int prefixBits,
                 struct in6_addr gw, unsigned ifindex, int *errOut) {
    if (errOut) { *errOut = 0; }
    if (add) {
        if (psn_route6_once(RTM_ADD, dst, prefixBits, gw, ifindex)) { return true; }
        if (errno == EEXIST) {
            psn_route6_once(RTM_DELETE, dst, prefixBits, gw, ifindex);
            if (psn_route6_once(RTM_ADD, dst, prefixBits, gw, ifindex)) { return true; }
        }
    } else {
        if (psn_route6_once(RTM_DELETE, dst, prefixBits, gw, ifindex)) { return true; }
        if (errno == ESRCH) { return true; }
    }
    if (errOut) { *errOut = errno; }
    return false;
}

#pragma mark - default route query

bool PSNDefaultRoute4(struct in_addr *gwOut, unsigned *ifindexOut,
                      char *ifnameOut, size_t ifnameLen) {
    int rs = socket(PF_ROUTE, SOCK_RAW, AF_INET);
    if (rs < 0) { return false; }

    struct { struct rt_msghdr hdr; char payload[512]; } msg;
    memset(&msg, 0, sizeof(msg));

    struct sockaddr_in dst;
    psn_sin(&dst, (struct in_addr){ .s_addr = 0 });        // 0.0.0.0 == default
    memcpy(msg.payload, &dst, sizeof(dst));

    const int myseq = 4242;
    msg.hdr.rtm_msglen  = (u_short)(sizeof(struct rt_msghdr) + PSN_RT_ROUNDUP(dst.sin_len));
    msg.hdr.rtm_version = RTM_VERSION;
    msg.hdr.rtm_type    = RTM_GET;
    msg.hdr.rtm_addrs   = RTA_DST;
    msg.hdr.rtm_pid     = getpid();
    msg.hdr.rtm_seq     = myseq;

    if (write(rs, &msg, msg.hdr.rtm_msglen) < 0) { close(rs); return false; }

    struct timeval tv = { .tv_sec = 3, .tv_usec = 0 };
    setsockopt(rs, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    char buf[2048];
    for (;;) {
        ssize_t n = read(rs, buf, sizeof(buf));
        if (n <= 0) { close(rs); return false; }
        struct rt_msghdr *r = (struct rt_msghdr *)buf;
        if (r->rtm_seq != myseq || r->rtm_pid != getpid()) { continue; }
        if (r->rtm_errno != 0) { close(rs); return false; }

        // Walk the sockaddr chain to find RTA_GATEWAY.
        char *cp = buf + sizeof(struct rt_msghdr);
        struct sockaddr *gw = NULL;
        for (int i = 0; i < 8; i++) {
            if (!(r->rtm_addrs & (1 << i))) { continue; }
            struct sockaddr *sa = (struct sockaddr *)cp;
            if ((1 << i) == RTA_GATEWAY) { gw = sa; }
            cp += PSN_RT_ROUNDUP(sa->sa_len ? sa->sa_len : sizeof(uint32_t));
        }

        // A default route whose gateway is link-level rather than an address
        // (a point-to-point cellular interface, for instance) gives no next
        // hop to hang a /32 exclusion off. Reporting 0.0.0.0 here would be
        // indistinguishable from a real answer, and the caller would install
        // an exclusion that cannot carry the relay's own upstream connection -
        // the tunnel would then loop its traffic back into itself. Fail
        // instead, so tunnel mode declines to start. Checked before any
        // out-param is written so a false return leaves them all untouched.
        if (gwOut && (!gw || gw->sa_family != AF_INET)) { close(rs); return false; }

        if (ifindexOut) { *ifindexOut = r->rtm_index; }
        if (ifnameOut && ifnameLen > 0) {
            ifnameOut[0] = 0;
            if_indextoname(r->rtm_index, ifnameOut);
        }
        if (gwOut) { *gwOut = ((struct sockaddr_in *)gw)->sin_addr; }
        close(rs);
        return true;   // plain C: `YES` is an <objc/objc.h> macro, not visible here
    }
}

#pragma mark - subnet coverage

bool PSNIPv4CoveredBySubnet(struct in_addr ip, struct in_addr ifAddr, struct in_addr ifMask) {
    if (ifMask.s_addr == 0) { return false; }   // a /0 "subnet" is not a LAN
    return (ip.s_addr & ifMask.s_addr) == (ifAddr.s_addr & ifMask.s_addr);
}

bool PSNIPv4CoveredByAnyLocalSubnet(struct in_addr ip) {
    struct ifaddrs *list = NULL;
    bool covered = false;
    if (getifaddrs(&list) != 0) { return false; }
    for (struct ifaddrs *p = list; p && !covered; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET || !p->ifa_netmask) { continue; }
        if (p->ifa_flags & IFF_LOOPBACK) { continue; }
        covered = PSNIPv4CoveredBySubnet(ip,
            ((struct sockaddr_in *)p->ifa_addr)->sin_addr,
            ((struct sockaddr_in *)p->ifa_netmask)->sin_addr);
    }
    freeifaddrs(list);
    return covered;
}

#pragma mark - teardown registry

// One exclusion entry: dst/32 via gw on ifindex. Sized for 1 upstream proxy +
// a handful of DNS resolvers; fixed storage because there is no malloc on the
// signal path.
#define PSN_MAX_EXCLUSIONS 12
typedef struct { struct in_addr ip, gw; unsigned ifindex; } PSNExclusion;

static int          gUtunFd  = -1;
static unsigned     gTunIdx  = 0;
static struct in_addr  gPeer4;
static struct in6_addr gPeer6;
static PSNExclusion gExcl[PSN_MAX_EXCLUSIONS];

static volatile sig_atomic_t gHaveDef1   = 0;
static volatile sig_atomic_t gHaveDef1v6 = 0;
static volatile sig_atomic_t gExclCount  = 0;

void PSNTeardownTrackUtun(int fd, unsigned ifindex,
                          struct in_addr peer4, struct in6_addr peer6) {
    gPeer4 = peer4;
    gPeer6 = peer6;
    gTunIdx = ifindex;
    gUtunFd = fd;
    gHaveDef1 = 0;
    gHaveDef1v6 = 0;
    gExclCount = 0;
}

void PSNTeardownUntrackUtun(void) {
    gUtunFd = -1;
    gTunIdx = 0;
    gHaveDef1 = 0;
    gHaveDef1v6 = 0;
    gExclCount = 0;
}

void PSNTeardownTrackDef1(void)   { gHaveDef1 = 1; }
void PSNTeardownTrackDef1v6(void) { gHaveDef1v6 = 1; }

bool PSNTeardownTrackExclusion(struct in_addr ip, struct in_addr gw, unsigned ifindex) {
    if (gExclCount >= PSN_MAX_EXCLUSIONS) { return false; }
    gExcl[gExclCount].ip = ip;
    gExcl[gExclCount].gw = gw;
    gExcl[gExclCount].ifindex = ifindex;
    gExclCount++;
    return true;
}

void PSNTunnelTeardown(bool closeUtunFd) {
    // Takeover routes first: this alone restores default routing, so do it
    // before anything that could fail. Flags are cleared BEFORE the deletes
    // so a nested/interrupted teardown cannot loop.
    if (gHaveDef1) {
        gHaveDef1 = 0;
        PSNRoute4Op(false, (struct in_addr){ .s_addr = 0 },                1, gPeer4, gTunIdx, NULL);
        PSNRoute4Op(false, (struct in_addr){ .s_addr = htonl(0x80000000) }, 1, gPeer4, gTunIdx, NULL);
    }
    if (gHaveDef1v6) {
        gHaveDef1v6 = 0;
        struct in6_addr any = IN6ADDR_ANY_INIT;
        struct in6_addr hi  = IN6ADDR_ANY_INIT;
        hi.s6_addr[0] = 0x80;
        PSNRoute6Op(false, any, 1, gPeer6, gTunIdx, NULL);
        PSNRoute6Op(false, hi,  1, gPeer6, gTunIdx, NULL);
    }
    while (gExclCount > 0) {
        gExclCount--;
        PSNRoute4Op(false, gExcl[gExclCount].ip, -1,
                    gExcl[gExclCount].gw, gExcl[gExclCount].ifindex, NULL);
    }
    if (closeUtunFd && gUtunFd >= 0) {
        int fd = gUtunFd;
        gUtunFd = -1;
        close(fd);   // the kernel purges any route still pointing at the utun
    }
}
