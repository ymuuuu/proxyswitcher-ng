# Changelog

## Unreleased — `feat/l3-tunnel-mode`

L3 tunnel mode: an opt-in forced-interception mode that captures traffic from apps which
ignore the cooperative iOS proxy. Closes issue #2.

12 commits off `main` at `740bf78`.

### The problem

The tweak sets the Wi-Fi proxy through `SCPreferences`. That is **cooperative** — the proxy
is a hint in a dictionary and each app decides whether to honour it. `NSURLSession` reads
it; Dart's `dart:io` socket layer and gRPC's C-core do not. No amount of fixing the
cooperative path helps, because those apps never use it.

### The fix

The root daemon creates a `utun`, takes over the routing table with the `def1` trick
(`0.0.0.0/1` + `128.0.0.0/1` rather than replacing `0.0.0.0/0`, so the system default
survives underneath and teardown cannot strand the device), and feeds captured packets
through a vendored userspace TCP/IP stack that turns each flow into a SOCKS5 connection to
the existing local relay, which speaks HTTP `CONNECT` upstream.

Cooperative mode stays the default and is byte-identical when the switch is off.

**Out of scope:** TLS decryption and certificate pinning. Getting the bytes to the proxy is
this work; what can be read of them is a separate problem — see `docs/REFERENCES.md`.

---

### Added

- **Tunnel mode** — opt-in, off by default, toggled in Settings. `utun` device, plain-C
  routing operations, a vendored `hev-socks5-tunnel` engine, and a controller with a health
  probe and fail-open recovery. (`c23413d`, `5a55805`, `198d524`)
- **Hostname recovery.** The tunnel works at L3 and only ever sees an IP, so the relay
  sniffs the TLS ClientHello SNI (or the HTTP `Host` header) and issues
  `CONNECT <hostname>:<port>` upstream instead of connecting by IP. (`a63dffd`)
- **IPv6 capture** — `::/1` + `8000::/1`, best-effort. Without it, v6-capable networks leak
  past an IPv4-only tunnel, because happy-eyeballs *prefers* v6. (`c23413d`)
- **"Exclude Apple services" preference, default ON.** Routes Apple's legacy `17.0.0.0/8`
  around the tunnel via the physical gateway. Without it, tunnel mode captures Apple's
  pinned system services, which then fail their handshake against the proxy — breaking push
  notifications, location services, Safari fraud warnings and universal links. (`f0deb9b`)
- **`--selftest` coverage** for the SOCKS5 request parser: six cases over a `socketpair()`,
  including the exact ten refusal bytes of the UDP blackhole and a CR-in-domain security
  case. (`f0deb9b`)
- **`--selftest-net`** — a non-destructive on-device smoke test: a `/32` into TEST-NET-2
  (unroutable by definition) added and removed, utun create/configure/close, and a check
  that the default route was untouched. (`c23413d`)

### Fixed

- **Tunnel mode took the device fully offline** (first device test). `PSNDefaultRoute4` used
  `RTM_GET` on `0.0.0.0`, which is a route *lookup*, not a default-route query — once
  `0.0.0.0/1` existed it matched *that* and returned the tunnel's own peer as "the physical
  gateway". Every exclusion was then pointed into the tunnel, so the relay's upstream
  connection looped back into itself. Replaced with a `sysctl(NET_RT_DUMP)` table walk
  matching `dst == 0.0.0.0 && netmask == 0.0.0.0`. Confirmed by the device's own log: 435
  looped flows in the broken build, **0** in the fixed one. (`998011f`)
- **Interface-scoped routes were being mistaken for the default.** iOS keeps a scoped
  default per cellular PDP context beside the real one; the table walk now skips
  `RTF_IFSCOPE`. (`998011f`)
- **Wi-Fi glyph vanished from the status bar** while the tunnel was up, with nothing
  replacing it. `-[SBWiFiManager isPrimaryInterface]` delegates to
  `-[NWSystemPathMonitor isWiFiPrimary]` — Network.framework/NECP, which evaluates the real
  routing table, where our `/1` pair wins. Fixed by setting the utun's **delegate
  interface** (`UTUN_OPT_SET_DELEGATE_INTERFACE`) to whichever interface holds the IPv4
  default route, the way real VPN tunnels do. Not cosmetic: `NWPathMonitor` is public API,
  so apps gating on connection type saw `other` instead of `wifi`. (`0144a61`)
- **Package was tagged `iphoneos-arm64`**, so `dpkg` refused it on an arm64e system. theos
  never reads `control`'s `Architecture` — `deb.mk` resolves it before `THEOS_PROJECT_DIR`
  is populated. Fixed with `override THEOS_PACKAGE_ARCH` in the root `Makefile`. (`9faa009`)
- **Teardown could not remove a non-`/32` exclusion.** The registry stored no netmask and
  deleted every entry as a host route, so the new Apple `/8` would have been installed and
  never removed. `PSNExclusion` now carries `maskBits`. (`f0deb9b`)
- **A crash handler consumed its own crash.** It called `_exit` after `kill`, so no crash
  report was ever generated. Handlers are also now installed *before* any route is touched.
  (`998011f`)
- **Header injection via the `CONNECT` request line.** A hostname from the sniffers or a
  SOCKS5 domain request went unvalidated into `CONNECT <host>:<port> HTTP/1.1\r\n`, where a
  CR would inject arbitrary headers. Added `PSNHostnameIsRequestLineSafe` (DNS alphabet
  only) and applied it on both paths. (`a63dffd`, `f162737`)
- **A logging "disk fallback" that treated a non-problem.** It was written to fix a bug that
  never existed — see "Retracted" below. (`ce25f15`)

### Changed

- `handleTunnelClient:` was 132 lines doing eight things; its SOCKS5 request parse is now a
  static helper, leaving the method at 91. Behaviour is identical — same reads in the same
  order, same refusal bytes, fd still closed exactly once on every path. The point was
  testability: the parser takes an `int fd` and can now be driven from a `socketpair()`.
  (`f162737`)
- `common/PSNPrefKeys.h` is now genuinely the single source of truth for cfprefs keys. Ten
  of eleven constants were unused — not by neglect, but because `CFSTR()` requires a
  compile-time literal, which an `NSString * const` is not, so the keys lived on as bare
  literals in four files. Each key is now a `#define` of the bare C literal with the
  `NSString` constant derived from it; adopted at all 36 call sites. (`f162737`)
- Shared logger, pref keys, and `host:port` parser extracted into `common/`. (`b7d9845`)

### Known limitations

- **Apple exclusion is IPv4 only.** The `::/1` + `8000::/1` takeover has no exclusion
  mechanism, so on a working-IPv6 network Apple traffic may still be captured and those
  services may still break.
- **QUIC is blackholed.** SOCKS5 `UDP ASSOCIATE` is refused with `0x07`, which forces
  affected clients to fall back to TCP. Deliberate — the bridge speaks HTTP `CONNECT`, which
  is TCP-only.
- **Tunnel mode requires an HTTP upstream proxy.** With `useSocks` on it refuses loudly and
  stays cooperative, rather than silently misbehaving.
- **TLS is a separate problem.** Captured Flutter traffic reaches the proxy and then fails
  the handshake, because Flutter statically links its own BoringSSL and never consults the
  iOS trust store. SSL Kill Switch cannot reach it. See `docs/REFERENCES.md`.
- **`maskBits` is untested.** Nothing exercises the new non-`/32` teardown path.

### Retracted

Recorded so nobody re-derives them. Both came from the roothide path trap, where
`/var/mobile/...` means one directory to an SSH shell (inside the jbroot) and another to the
daemon (outside it); the real filesystem is at `/rootfs/` from a shell.

- *"File logging has never worked."* It always worked. The shell was reading the jbroot's
  empty directory.
- *"cfprefsd ignores direct plist writes."* Writes from SSH went to the jbroot's plist, which
  nothing reads. cfprefsd was never involved.

A third claim, *"`PSNLogPath()` is dead code"*, was also wrong — `prefs/PSNLogsController.m`
calls it.

### Verification

- **Device test 1** found the offline bug above.
- **Device test 2** (`dev.35`) confirmed the fix, with real traffic reaching the proxy and
  hostname recovery working.
- **Issue #2 proven** (`dev.37`) by a controlled A/B on a real Flutter app, same screens
  three minutes apart:

  | Host | Stack | Tunnel OFF | Tunnel ON |
  |---|---|---|---|
  | `api2.amplitude.com` | native `NSURLSession` | yes | yes |
  | `server2.finchcare.com` | Dart `dart:io` | **no** | **yes** |
  | `firestore.googleapis.com` | gRPC C-core | **no** | **yes** |

  The control run is what makes this count: "Flutter traffic appeared" is also what a
  cooperating app produces. Two independent stacks that ignore the system proxy were
  captured only with the tunnel up.

Every build must still pass `proxyswitcherngd --selftest`. Kernel and network behaviour has
no CI coverage — there is no device in CI — and is verified by hand.
