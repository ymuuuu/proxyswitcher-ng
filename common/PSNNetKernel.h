#ifndef PSN_NET_KERNEL_H
#define PSN_NET_KERNEL_H

// The iPhoneOS SDK ships none of <sys/kern_control.h>, <sys/sys_domain.h>,
// <net/if_utun.h>, <net/route.h> or <netinet6/in6_var.h>. These are stable XNU
// ABI, reproduced here so the daemon builds against the stock SDK.
// Validated on-device: docs/PHASE0-UTUN-FINDINGS.md.

#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>
#include <netinet/in.h>

// --- sys/sys_domain.h ---
#define SYSPROTO_CONTROL        2
#define AF_SYS_CONTROL          2

// --- sys/kern_control.h ---
#define MAX_KCTL_NAME           96
#define CTLIOCGINFO             _IOWR('N', 3, struct ctl_info)

struct ctl_info {
    u_int32_t   ctl_id;
    char        ctl_name[MAX_KCTL_NAME];
};

struct sockaddr_ctl {
    u_char      sc_len;
    u_char      sc_family;      // AF_SYSTEM
    u_int16_t   ss_sysaddr;     // AF_SYS_CONTROL
    u_int32_t   sc_id;
    u_int32_t   sc_unit;
    u_int32_t   sc_reserved[5];
};

// --- net/if_utun.h ---
#define UTUN_CONTROL_NAME       "com.apple.net.utun_control"
#define UTUN_OPT_IFNAME         2
// setsockopt on the control socket; value is the delegate's interface name
// (char[], len <= IFNAMSIZ-1, NUL not required - the kernel copies len bytes
// and terminates itself), and it lands on ifnet_set_delegate() in the kernel.
// Same value in xnu-8019, -8792, -10002, -11215 (iOS 15-18).
#define UTUN_OPT_SET_DELEGATE_INTERFACE 15

// --- net/route.h ---
#define RTM_VERSION             5
#define RTM_ADD                 0x1
#define RTM_DELETE              0x2
#define RTM_GET                 0x4

#define RTF_UP                  0x1
#define RTF_GATEWAY             0x2
#define RTF_HOST                0x4
#define RTF_STATIC              0x800
// Set on a route that only applies to sockets scoped to one interface. iOS
// keeps a scoped default per cellular PDP context alongside the real one, so
// a table walk that ignores this flag can pick cellular while Wi-Fi is
// primary. netstat renders it as the "I" flag.
#define RTF_IFSCOPE             0x1000000

#define RTA_DST                 0x1
#define RTA_GATEWAY             0x2
#define RTA_NETMASK             0x4

// sysctl MIB name for the routing-table dump, used by PSNDefaultRoute4:
// { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0 }.
#define NET_RT_DUMP             1

struct rt_metrics {
    u_int32_t   rmx_locks;
    u_int32_t   rmx_mtu;
    u_int32_t   rmx_hopcount;
    int32_t     rmx_expire;
    u_int32_t   rmx_recvpipe;
    u_int32_t   rmx_sendpipe;
    u_int32_t   rmx_ssthresh;
    u_int32_t   rmx_rtt;
    u_int32_t   rmx_rttvar;
    u_int32_t   rmx_pksent;
    u_int32_t   rmx_state;
    u_int32_t   rmx_filler[3];
};

struct rt_msghdr {
    u_short     rtm_msglen;
    u_char      rtm_version;
    u_char      rtm_type;
    u_short     rtm_index;
    int         rtm_flags;
    int         rtm_addrs;
    pid_t       rtm_pid;
    int         rtm_seq;
    int         rtm_errno;
    int         rtm_use;
    u_int32_t   rtm_inits;
    struct rt_metrics rtm_rmx;
};

// --- netinet6/in6_var.h ---
struct in6_addrlifetime {
    time_t      ia6t_expire;
    time_t      ia6t_preferred;
    u_int32_t   ia6t_vltime;
    u_int32_t   ia6t_pltime;
};

struct in6_aliasreq {
    char                    ifra_name[IFNAMSIZ];
    struct sockaddr_in6     ifra_addr;
    struct sockaddr_in6     ifra_dstaddr;
    struct sockaddr_in6     ifra_prefixmask;
    int                     ifra_flags;
    struct in6_addrlifetime ifra_lifetime;
};

#define SIOCAIFADDR_IN6         _IOW('i', 26, struct in6_aliasreq)
#define ND6_INFINITE_LIFETIME   0xffffffffU

// Route-message sockaddrs are padded to a 4-byte boundary. Named PSN_RT_ROUNDUP
// (not ROUNDUP) so this shared header cannot collide with anyone else's macro.
#define PSN_RT_ROUNDUP(a) \
    ((a) > 0 ? (1 + (((a) - 1) | (sizeof(uint32_t) - 1))) : sizeof(uint32_t))

#endif // PSN_NET_KERNEL_H
