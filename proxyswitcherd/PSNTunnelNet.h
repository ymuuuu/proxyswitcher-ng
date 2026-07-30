#ifndef PSN_TUNNEL_NET_H
#define PSN_TUNNEL_NET_H

#include <stdbool.h>
#include <stddef.h>
#include <netinet/in.h>

// Plain-C routing-table operations and the teardown registry for tunnel mode.
// Signal-safety contract: PSNTunnelTeardown and everything it calls use only
// async-signal-safe calls (socket/write/close/memcpy). No ObjC and no logging
// anywhere in this file - the caller logs, on the normal path only. The one
// allocation in this file is the sysctl dump buffer in PSNDefaultRoute4,
// which is never reachable from the signal path.

#ifdef __cplusplus
extern "C" {
#endif

// Install (add=true) or remove (add=false) one route via PF_ROUTE.
// maskBits < 0 means a host route (/32); otherwise a CIDR mask 0..32.
// Add is idempotent: EEXIST triggers one delete+retry (stale routes survive a
// daemon crash because KeepAlive restarts us and /32 exclusions point at the
// physical gateway, not at the dead utun). Delete treats ESRCH as success.
// Returns false only on a real failure; errOut receives errno when set.
bool PSNRoute4Op(bool add, struct in_addr dst, int maskBits,
                 struct in_addr gw, unsigned ifindex, int *errOut);

// IPv6 twin. prefixBits is mandatory (0..128); there is no host-route special
// case because the v6 takeover uses /1 prefixes only.
bool PSNRoute6Op(bool add, struct in6_addr dst, int prefixBits,
                 struct in6_addr gw, unsigned ifindex, int *errOut);

// The current IPv4 default gateway, interface index and name, found by
// walking the sysctl NET_RT_DUMP table and matching destination 0.0.0.0 with
// netmask 0.0.0.0 - an RTM_GET lookup would match the 0.0.0.0/1 takeover
// instead and return the tunnel peer (device test 1). Entries whose
// interface is our own tracked utun are rejected outright. Returns false
// when there is no default route (e.g. Wi-Fi down), and also when gwOut was
// requested but the default route's gateway is link-level rather than an
// address - a /32 exclusion needs a real next hop. On false no out-param is
// written.
bool PSNDefaultRoute4(struct in_addr *gwOut, unsigned *ifindexOut,
                      char *ifnameOut, size_t ifnameLen);

// Pure: is ip inside (ifAddr & ifMask)? A zero mask counts as "no cover".
// Used to decide which DNS resolvers need a /32 exclusion: a resolver already
// covered by a connected subnet route (typically the LAN gateway) never
// enters the tunnel, because e.g. a /24 beats the /1 takeover.
bool PSNIPv4CoveredBySubnet(struct in_addr ip, struct in_addr ifAddr, struct in_addr ifMask);

// Same question across every AF_INET interface reported by getifaddrs.
bool PSNIPv4CoveredByAnyLocalSubnet(struct in_addr ip);

// --- teardown registry: what the running tunnel has installed ---
// Written only on the controller's serial queue; read by PSNTunnelTeardown
// on any path. Flags are sig_atomic_t and are always set AFTER the data they
// guard, cleared BEFORE the delete they gate.

void PSNTeardownTrackUtun(int fd, unsigned ifindex,
                          struct in_addr peer4, struct in6_addr peer6);
void PSNTeardownUntrackUtun(void);
void PSNTeardownTrackDef1(void);        // the 0.0.0.0/1 + 128.0.0.0/1 pair is in
void PSNTeardownTrackDef1v6(void);      // the ::/1 + 8000::/1 pair is in
bool PSNTeardownTrackExclusion(struct in_addr ip, struct in_addr gw, unsigned ifindex); // false if registry full

// Removes every route the registry knows about, idempotently, in reverse
// dependency order (takeover first, exclusions last). When closeUtunFd is
// true (signal path) it also closes the utun fd, which makes the kernel purge
// anything the deletes missed. Safe to call twice, safe from a signal handler.
void PSNTunnelTeardown(bool closeUtunFd);

#ifdef __cplusplus
}
#endif

#endif // PSN_TUNNEL_NET_H
