#import <Foundation/Foundation.h>

// RFC 2544 benchmarking range: reserved, never legitimately routed, and the
// range hev-socks5-tunnel documents for its own tun. The peer address is what
// the /1 routes point at.
extern NSString * const kPSNTunLocalIPv4;   // 198.18.0.1
extern NSString * const kPSNTunPeerIPv4;    // 198.18.0.2
extern NSString * const kPSNTunLocalIPv6;   // fc00::1 (ULA)
extern NSString * const kPSNTunPeerIPv6;    // fc00::2
extern const unsigned kPSNTunMTU;           // 1500 - matches en0 and the engine config

@interface PSNTunnelDevice : NSObject

@property (nonatomic, readonly) int fd;
@property (nonatomic, readonly, copy) NSString *interfaceName;
@property (nonatomic, readonly) unsigned interfaceIndex;

// Creates a utun with a KERNEL-ASSIGNED unit (sc_unit = 0; asking for a
// specific low unit returns EBUSY - iOS already holds utun0-utun4).
// Registers the fd with the teardown tracker so the signal path can close it.
- (BOOL)openDevice;

// Assigns the v4 point-to-point pair, sets MTU, brings the link up. IPv6 is
// attempted and logged but not fatal: without it, v6-capable networks would
// leak past an IPv4-only tunnel, so the controller still installs ::/1 +
// 8000::/1 only when this returns YES for v6 (see -ipv6Ready).
- (BOOL)configureInterfaces;

@property (nonatomic, readonly) BOOL ipv6Ready;

// Closing the fd destroys the interface and purges every route pointing at
// it. Unregisters from the teardown tracker first.
// ONLY call this once you know nothing else is still reading the fd.
- (void)closeDevice;

// Drops the device WITHOUT closing the fd, and unregisters it from the
// teardown tracker so the signal path will not close it either. Used only
// when the tunnel engine failed to exit and may still be blocked in read(2)
// on this descriptor: closing it would free the fd NUMBER for immediate reuse
// by any other thread, and the engine's next read would land on an unrelated
// descriptor. A leaked fd is strictly better than that.
- (void)abandonDevice;

@end
