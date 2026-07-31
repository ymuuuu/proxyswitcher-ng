#import "PSNTunnelDevice.h"
#import "PSNTunnelNet.h"
#import "PSNNetKernel.h"
#import "PSNLog.h"

#import <sys/sockio.h>
#import <netinet6/in6.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

NSString * const kPSNTunLocalIPv4 = @"198.18.0.1";
NSString * const kPSNTunPeerIPv4  = @"198.18.0.2";
NSString * const kPSNTunLocalIPv6 = @"fc00::1";
NSString * const kPSNTunPeerIPv6  = @"fc00::2";
const unsigned kPSNTunMTU = 1500;

@implementation PSNTunnelDevice {
    int _fd;
    NSString *_ifname;
    unsigned _ifindex;
    BOOL _ipv6Ready;
}

- (instancetype)init {
    if ((self = [super init])) { _fd = -1; }
    return self;
}

- (int)fd { return _fd; }
- (NSString *)interfaceName { return _ifname; }
- (unsigned)interfaceIndex { return _ifindex; }
- (BOOL)ipv6Ready { return _ipv6Ready; }

- (BOOL)openDevice {
    if (_fd >= 0) { return YES; }

    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) {
        PSLog(@"[tunnel] socket(PF_SYSTEM): %s", strerror(errno));
        return NO;
    }

    struct ctl_info ci;
    memset(&ci, 0, sizeof(ci));
    strlcpy(ci.ctl_name, UTUN_CONTROL_NAME, sizeof(ci.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &ci) < 0) {
        PSLog(@"[tunnel] ioctl(CTLIOCGINFO): %s", strerror(errno));
        close(fd);
        return NO;
    }

    struct sockaddr_ctl sc;
    memset(&sc, 0, sizeof(sc));
    sc.sc_len     = sizeof(sc);
    sc.sc_family  = AF_SYSTEM;
    sc.ss_sysaddr = AF_SYS_CONTROL;
    sc.sc_id      = ci.ctl_id;
    sc.sc_unit    = 0;   // MUST be 0: auto-assign. Unit N+1 means utunN, and
                         // iOS already holds utun0-utun4, so low units EBUSY.

    if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) < 0) {
        int e = errno;
        PSLog(@"[tunnel] utun connect: %s", strerror(e));
        if (e == EPERM || e == EACCES) {
            PSLog(@"[tunnel] EPERM/EACCES: sandbox or entitlements refused utun creation");
        }
        close(fd);
        return NO;
    }

    char name[IFNAMSIZ] = {0};
    socklen_t nlen = sizeof(name);
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, name, &nlen) < 0) {
        PSLog(@"[tunnel] getsockopt(UTUN_OPT_IFNAME): %s", strerror(errno));
        close(fd);
        return NO;
    }

    _fd = fd;
    _ifname = [NSString stringWithUTF8String:name];
    _ifindex = if_nametoindex(name);
    if (_ifindex == 0) {
        PSLog(@"[tunnel] if_nametoindex(%s) == 0", name);
        close(fd);
        _fd = -1;
        _ifname = nil;
        return NO;
    }

    struct in_addr peer4;  inet_pton(AF_INET,  kPSNTunPeerIPv4.UTF8String,  &peer4);
    struct in6_addr peer6; inet_pton(AF_INET6, kPSNTunPeerIPv6.UTF8String, &peer6);
    PSNTeardownTrackUtun(_fd, _ifindex, peer4, peer6);

    // Delegate interface: tell the kernel which physical interface this tunnel
    // rides on (ifnet_set_delegate via the utun control socket). Once the /1
    // takeover routes are in, nw_path's longest-prefix match lands on this
    // utun and SpringBoard drops the Wi-Fi glyph; with the delegate set the
    // path can still see the physical interface underneath. Resolved NOW, at
    // device creation, which always runs before any tunnel route is installed
    // (controller resolves the same default route earlier on the same serial
    // queue). Best-effort: this only changes how the tunnel is perceived, so
    // a failure is logged and openDevice still succeeds.
    char delegate[IFNAMSIZ] = {0};
    if (!PSNDefaultRoute4(NULL, NULL, delegate, sizeof(delegate)) || delegate[0] == 0) {
        PSLog(@"[tunnel] %@ delegate interface NOT set: no IPv4 default route", _ifname);
    } else if (setsockopt(_fd, SYSPROTO_CONTROL, UTUN_OPT_SET_DELEGATE_INTERFACE,
                          delegate, (socklen_t)strlen(delegate)) < 0) {
        PSLog(@"[tunnel] %@ setsockopt(UTUN_OPT_SET_DELEGATE_INTERFACE %s) failed: %s",
              _ifname, delegate, strerror(errno));
    } else {
        PSLog(@"[tunnel] %@ delegate interface set to %s", _ifname, delegate);
    }

    PSLog(@"[tunnel] created %@ (fd=%d ifindex=%u)", _ifname, _fd, _ifindex);
    return YES;
}

static void psn_dev_sin(struct sockaddr_in *s, NSString *addr) {
    memset(s, 0, sizeof(*s));
    s->sin_len = sizeof(*s);
    s->sin_family = AF_INET;
    if (addr) { inet_pton(AF_INET, addr.UTF8String, &s->sin_addr); }
}

static void psn_dev_sin6(struct sockaddr_in6 *s, NSString *addr) {
    memset(s, 0, sizeof(*s));
    s->sin6_len = sizeof(*s);
    s->sin6_family = AF_INET6;
    if (addr) { inet_pton(AF_INET6, addr.UTF8String, &s->sin6_addr); }
}

static void psn_dev_sin6_prefix(struct sockaddr_in6 *s, int bits) {
    memset(s, 0, sizeof(*s));
    s->sin6_len = sizeof(*s);
    s->sin6_family = AF_INET6;
    for (int i = 0; i < 16 && bits > 0; i++, bits -= 8) {
        s->sin6_addr.s6_addr[i] = (bits >= 8) ? 0xff : (uint8_t)(0xff << (8 - bits));
    }
}

- (BOOL)configureInterfaces {
    if (_fd < 0) { return NO; }

    // --- IPv4 point-to-point pair ---
    int s4 = socket(AF_INET, SOCK_DGRAM, 0);
    if (s4 < 0) { PSLog(@"[tunnel] socket(AF_INET): %s", strerror(errno)); return NO; }

    struct ifaliasreq ifra;
    memset(&ifra, 0, sizeof(ifra));
    strlcpy(ifra.ifra_name, _ifname.UTF8String, sizeof(ifra.ifra_name));
    psn_dev_sin((struct sockaddr_in *)&ifra.ifra_addr, kPSNTunLocalIPv4);
    psn_dev_sin((struct sockaddr_in *)&ifra.ifra_broadaddr, kPSNTunPeerIPv4);  // dstaddr on p2p
    psn_dev_sin((struct sockaddr_in *)&ifra.ifra_mask, @"255.255.255.255");

    if (ioctl(s4, SIOCAIFADDR, &ifra) < 0) {
        PSLog(@"[tunnel] SIOCAIFADDR %@ %@->%@: %s",
              _ifname, kPSNTunLocalIPv4, kPSNTunPeerIPv4, strerror(errno));
        close(s4);
        return NO;
    }

    // --- MTU: pinned so the interface and the engine read buffer agree ---
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, _ifname.UTF8String, sizeof(ifr.ifr_name));
    ifr.ifr_mtu = (int)kPSNTunMTU;
    if (ioctl(s4, SIOCSIFMTU, &ifr) < 0) {
        PSLog(@"[tunnel] SIOCSIFMTU %u: %s", kPSNTunMTU, strerror(errno));
        close(s4);
        return NO;
    }

    // --- link up ---
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, _ifname.UTF8String, sizeof(ifr.ifr_name));
    if (ioctl(s4, SIOCGIFFLAGS, &ifr) == 0) {
        ifr.ifr_flags |= (IFF_UP | IFF_RUNNING);
        if (ioctl(s4, SIOCSIFFLAGS, &ifr) < 0) {
            PSLog(@"[tunnel] SIOCSIFFLAGS up: %s", strerror(errno));
            close(s4);
            return NO;
        }
    }
    close(s4);
    PSLog(@"[tunnel] %@ ipv4 %@ -> %@ mtu %u, up",
          _ifname, kPSNTunLocalIPv4, kPSNTunPeerIPv4, kPSNTunMTU);

    // --- IPv6 pair, best-effort ---
    int s6 = socket(AF_INET6, SOCK_DGRAM, 0);
    if (s6 < 0) {
        PSLog(@"[tunnel] socket(AF_INET6): %s (continuing IPv4-only)", strerror(errno));
        return YES;
    }

    struct in6_aliasreq ifra6;
    memset(&ifra6, 0, sizeof(ifra6));
    strlcpy(ifra6.ifra_name, _ifname.UTF8String, sizeof(ifra6.ifra_name));
    psn_dev_sin6(&ifra6.ifra_addr, kPSNTunLocalIPv6);
    psn_dev_sin6(&ifra6.ifra_dstaddr, kPSNTunPeerIPv6);
    psn_dev_sin6_prefix(&ifra6.ifra_prefixmask, 128);   // explicit /128, as proven by the spike
    ifra6.ifra_lifetime.ia6t_vltime = ND6_INFINITE_LIFETIME;
    ifra6.ifra_lifetime.ia6t_pltime = ND6_INFINITE_LIFETIME;

    if (ioctl(s6, SIOCAIFADDR_IN6, &ifra6) < 0) {
        PSLog(@"[tunnel] SIOCAIFADDR_IN6 %@: %s (continuing IPv4-only)",
              _ifname, strerror(errno));
        close(s6);
        return YES;
    }
    close(s6);
    _ipv6Ready = YES;
    PSLog(@"[tunnel] %@ ipv6 %@ -> %@", _ifname, kPSNTunLocalIPv6, kPSNTunPeerIPv6);
    return YES;
}

- (void)closeDevice {
    if (_fd < 0) { return; }
    PSNTeardownUntrackUtun();   // registry forgets the fd BEFORE we close it
    PSLog(@"[tunnel] destroying %@", _ifname);
    close(_fd);
    [self forgetState];
}

// See the header: never close a descriptor another thread may still be
// reading. The kernel destroys the interface when the last reference goes
// away, which for a still-running engine means process exit - and KeepAlive
// makes that a bounded, recoverable outcome.
- (void)abandonDevice {
    if (_fd < 0) { return; }
    PSNTeardownUntrackUtun();
    PSLog(@"[tunnel] abandoning %@ (fd %d intentionally leaked; engine still running)",
          _ifname, _fd);
    [self forgetState];
}

- (void)forgetState {
    _fd = -1;
    _ifname = nil;
    _ifindex = 0;
    _ipv6Ready = NO;
}

@end
