#include "PSNTunnelNet.h"
#include "PSNNetKernel.h"

#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
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

#pragma mark - teardown registry storage

// One exclusion entry: dst/maskBits via gw on ifindex, maskBits on the
// PSNRoute4Op convention (<0 == /32 host route). The mask must be stored:
// teardown cannot remove a 17.0.0.0/8 with a /32 delete. Sized for 1 upstream
// proxy + the Apple /8 + a handful of DNS resolvers; fixed storage because
// there is no malloc on the signal path. Declared above the default-route
// query because that query reads gTunIdx (it must never return our own utun
// as "the physical gateway"); the registry functions themselves are further
// down.
#define PSN_MAX_EXCLUSIONS 12
typedef struct { struct in_addr ip, gw; unsigned ifindex; int maskBits; } PSNExclusion;

static int          gUtunFd  = -1;
static unsigned     gTunIdx  = 0;
static struct in_addr  gPeer4;
static struct in6_addr gPeer6;
static PSNExclusion gExcl[PSN_MAX_EXCLUSIONS];

static volatile sig_atomic_t gHaveDef1   = 0;
static volatile sig_atomic_t gHaveDef1v6 = 0;
static volatile sig_atomic_t gExclCount  = 0;

#pragma mark - default route query

// sysctl NET_RT_DUMP table walk - NOT RTM_GET. RTM_GET on 0.0.0.0 is a route
// LOOKUP for the address 0.0.0.0, and once the 0.0.0.0/1 takeover exists the
// lookup matches that /1 (more specific than /0): it returns the tunnel peer
// and the utun's index as "the physical gateway". The next start call then
// installed the upstream /32 exclusion INTO the tunnel and deadlocked every
// flow (device test 1, docs/L3-TUNNEL-PROGRESS.md). The dump is a table
// query: the default route is the entry whose destination AND netmask are
// both 0.0.0.0 - not any route that merely covers 0.0.0.0.
//
// The malloc here is fine: this function is NOT reachable from the signal
// path (only PSNTunnelTeardown is). Everything PSNTunnelTeardown can call
// remains socket/write/close/memcpy-only.
bool PSNDefaultRoute4(struct in_addr *gwOut, unsigned *ifindexOut,
                      char *ifnameOut, size_t ifnameLen) {
    int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0 };
    size_t needed = 0;
    if (sysctl(mib, 6, NULL, &needed, NULL, 0) < 0 || needed == 0) { return false; }
    char *buf = malloc(needed);
    if (!buf) { return false; }
    if (sysctl(mib, 6, buf, &needed, NULL, 0) < 0) { free(buf); return false; }

    bool ok = false;
    char *lim = buf + needed;
    for (char *next = buf; next < lim && !ok;) {
        struct rt_msghdr *r = (struct rt_msghdr *)next;
        if (r->rtm_msglen < (int)sizeof(struct rt_msghdr)) { break; }  // corrupt dump: stop
        next += r->rtm_msglen;

        if (!(r->rtm_flags & RTF_UP)) { continue; }

        // Skip interface-scoped defaults. iOS keeps one per cellular PDP
        // context beside the real default (device test 1 saw "default via
        // 10.46.111.173 dev pdp_ip0" flagged I, next to the live Wi-Fi one).
        // A scoped route only applies to sockets bound to that interface, and
        // the relay binds to none - IP_BOUND_IF is proven not to escape the
        // tunnel, so the /32 exclusion is the only mechanism and it has to sit
        // on the unscoped path the relay actually uses. Taking a scoped entry
        // would point the exclusion at cellular while Wi-Fi carries the
        // traffic, and the upstream proxy on the LAN would be unreachable.
        if (r->rtm_flags & RTF_IFSCOPE) { continue; }

        // Unpack the sockaddr chain by rtm_addrs bit position. A zero sa_len
        // entry still occupies one uint32_t in the message (XNU SA_SIZE).
        char *cp = (char *)r + sizeof(struct rt_msghdr);
        char *end = next;
        struct sockaddr *dst = NULL, *gw = NULL, *mask = NULL;
        for (int i = 0; i < 8 && cp < end; i++) {
            if (!(r->rtm_addrs & (1 << i))) { continue; }
            struct sockaddr *sa = (struct sockaddr *)cp;
            if ((1 << i) == RTA_DST)          { dst = sa; }
            else if ((1 << i) == RTA_GATEWAY) { gw = sa; }
            else if ((1 << i) == RTA_NETMASK) { mask = sa; }
            cp += PSN_RT_ROUNDUP(sa->sa_len ? sa->sa_len : sizeof(uint32_t));
        }

        // Destination must be exactly 0.0.0.0 ...
        if (!dst || dst->sa_family != AF_INET ||
            ((struct sockaddr_in *)dst)->sin_addr.s_addr != 0) { continue; }

        // ... and the netmask exactly 0.0.0.0 (or absent/empty). That is what
        // distinguishes the default route from the 0.0.0.0/1 takeover entry,
        // which covers 0.0.0.0 but has mask 128.0.0.0.
        if (mask && mask->sa_len > 0 && mask->sa_family == AF_INET &&
            ((struct sockaddr_in *)mask)->sin_addr.s_addr != 0) { continue; }

        // Defence in depth: never hand back our own tunnel, whatever the
        // table says. gTunIdx is this file's teardown-registry state, read
        // directly rather than duplicated.
        if (gTunIdx != 0 && r->rtm_index == (u_short)gTunIdx) { continue; }

        // Unchanged contract: a default route whose gateway is link-level
        // rather than an address (a point-to-point cellular interface, for
        // instance) gives no next hop to hang a /32 exclusion off. Reporting
        // 0.0.0.0 here would be indistinguishable from a real answer, and the
        // caller would install an exclusion that cannot carry the relay's own
        // upstream connection - the tunnel would then loop its traffic back
        // into itself. Fail instead, so tunnel mode declines to start. Done
        // before any out-param is written so a false return leaves them all
        // untouched.
        // `continue`, not `break`: this is a table walk, so an unusable
        // candidate must not abandon the search while a usable default may
        // still follow it. If none qualifies the loop ends with ok == false,
        // which is the same answer `break` would have given.
        if (gwOut && (!gw || gw->sa_family != AF_INET)) { continue; }

        if (ifindexOut) { *ifindexOut = r->rtm_index; }
        if (ifnameOut && ifnameLen > 0) {
            ifnameOut[0] = 0;
            if_indextoname(r->rtm_index, ifnameOut);
        }
        if (gwOut) { *gwOut = ((struct sockaddr_in *)gw)->sin_addr; }
        ok = true;
    }

    free(buf);
    return ok;
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

bool PSNTeardownTrackExclusion(struct in_addr ip, struct in_addr gw, unsigned ifindex,
                               int maskBits) {
    if (gExclCount >= PSN_MAX_EXCLUSIONS) { return false; }
    gExcl[gExclCount].ip = ip;
    gExcl[gExclCount].gw = gw;
    gExcl[gExclCount].ifindex = ifindex;
    gExcl[gExclCount].maskBits = maskBits;
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
        PSNRoute4Op(false, gExcl[gExclCount].ip, gExcl[gExclCount].maskBits,
                    gExcl[gExclCount].gw, gExcl[gExclCount].ifindex, NULL);
    }
    if (closeUtunFd && gUtunFd >= 0) {
        int fd = gUtunFd;
        gUtunFd = -1;
        close(fd);   // the kernel purges any route still pointing at the utun
    }
}
