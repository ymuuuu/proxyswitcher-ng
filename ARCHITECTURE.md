# Architecture

How ProxySwitcher-ng is put together, end to end.

## Overview

The tweak has two runtime pieces that never link against each other. They
communicate only through a shared preferences domain and Darwin notifications:

1. A **Settings panel** (a PreferenceLoader bundle) where you configure things.
2. A **root daemon** that actually writes the Wi-Fi proxy.

```
+-------------------------------------------------------------+
|  Settings.app                                               |
|                                                             |
|   PreferenceLoader  ->  ProxySwitcherNG.bundle (arm64e)     |
|                          MBRootListController (panel)       |
|                          MBProfileEditController (editor)   |
|                          MBLogsController (log viewer)      |
+----------------------------|--------------------------------+
                             |  writes prefs (mobile domain)
                             |  posts Darwin notifications
                             v
        io.ymuu.proxyswitcherng  (CFPreferences domain)
        io.ymuu.proxyswitcherng/settingschanged  (notification)
        io.ymuu.proxyswitcherng/clearlog         (notification)
                             |
                             v
+-------------------------------------------------------------+
|  proxyswitcherngd  (root LaunchDaemon, arm64)               |
|                                                             |
|   observes settingschanged, clearlog, and the system        |
|   com.apple.system.config.network_change                    |
|                                                             |
|   MBWiFiProxyHandler:                                        |
|     read prefs -> resolve active proxy ->                    |
|     find Wi-Fi service -> write proxy keys ->               |
|     SCPreferences Commit + Apply                            |
+----------------------------|--------------------------------+
                             v
                 SystemConfiguration dynamic store
                 (the live Wi-Fi service Proxies dict)
```

## Components

### Settings panel (`prefs/`)

A compiled `arm64e` PreferenceBundle, `ProxySwitcherNG.bundle`, installed to
`/Library/PreferenceBundles`. It must be `arm64e` because iOS 16 Settings loads
preference bundles into an `arm64e` host.

- **`MBRootListController`** (`PSListController`) is the main panel. It loads the
  static rows from `Root.plist`, then builds the dynamic sections in code:
  - the Profiles section (Manual row, one row per saved profile, Add Profile),
    inserted above the Diagnostics group;
  - the About footer with version and build.
  It owns the class methods that read and write the profiles array and the
  active proxy through `CFPreferences` in the `mobile` user domain, and posts
  `settingschanged` after changes. The `Apply` bar button re-posts
  `settingschanged` and runs the connectivity check.
- **`MBProfileEditController`** (`PSListController`) is the Name / Host / Port
  editor. It validates host and port and calls back into
  `MBRootListController` to add or update a profile.
- **`MBLogsController`** (`PSViewController`) shows the log file in a monospaced
  text view, with Refresh and Clear. Clear posts `clearlog`.

The panel is registered with the system by a PreferenceLoader entry plist at
`layout/Library/PreferenceLoader/Preferences/ProxySwitcherNG.plist`, which points
Settings at the bundle and its `MBRootListController`, and carries the row icon.

### Daemon (`proxyswitcherd/`)

`proxyswitcherngd`, a standalone `arm64` LaunchDaemon installed to `/usr/bin`
with a plist in `/Library/LaunchDaemons`. It is standalone (never injected into
another process), so it does not need to be `arm64e`; an `arm64e` build would in
fact fail to exec on this setup.

- **`main.m`** registers three Darwin observers (`settingschanged`, `clearlog`,
  and the system `network_change`), applies once at launch, then runs the loop.
  It also has a `--selftest` mode that exercises the `host:port` parser.
- **`MBWiFiProxyHandler`** does the work in `applyFromPreferences`:
  1. read `enabled`, `server`, `port`, `activeProxy`, `logging` from the
     `io.ymuu.proxyswitcherng` domain (with a raw-plist fallback if cfprefsd
     returns nothing);
  2. if `activeProxy` is set and parses as `host:port`, it overrides the manual
     server and port;
  3. decide whether the proxy should be on (`enabled && server && port`);
  4. create `SCPreferences`, lock, find the Wi-Fi service by interface, deep-copy
     the services dict, and set or clear the HTTP and HTTPS proxy keys;
  5. commit and apply, then unlock.
  Writes are guarded so an unchanged state is skipped, and the port is always a
  number so SystemConfiguration accepts it.

### Layout and packaging (`layout/`, `control`, `Makefile`)

- `layout/` holds the PreferenceLoader entry plist and the DEBIAN maintainer
  scripts (the `postinst` bootstraps the daemon and normalizes ownership).
- Root `Makefile` aggregates the `proxyswitcherd` and `prefs` subprojects under
  the `rootless` packaging scheme.
- `control` declares the package (`io.ymuu.proxyswitcherng`, arch
  `iphoneos-arm64`, depends on `preferenceloader`).

## Data model

Preferences domain: **`io.ymuu.proxyswitcherng`** (read and written in the
`mobile` user domain via `CFPreferences`).

| Key | Type | Meaning |
| --- | --- | --- |
| `enabled` | bool | Master proxy on/off. |
| `server` | string | Manual proxy host. |
| `port` | string or number | Manual proxy port (coerced to a number in the daemon). |
| `activeProxy` | string | `host:port` of the selected profile. Overrides manual when set. |
| `profiles` | array | List of `{ name, value }` where `value` is `host:port`. UI only. |
| `logging` | bool | Enables file logging in the daemon. |

Notifications (Darwin):

| Name | Posted by | Effect |
| --- | --- | --- |
| `io.ymuu.proxyswitcherng/settingschanged` | panel | daemon re-applies from prefs |
| `io.ymuu.proxyswitcherng/clearlog` | Logs page | daemon truncates the log file |
| `com.apple.system.config.network_change` | system | daemon re-applies on network change |

Log file: `/var/mobile/Library/Logs/ProxySwitcherNG.log` (root-owned, `0644`;
written by the daemon, read by the Logs page, cleared via `clearlog`).

## Build and distribution

- The **`arm64e` panel bundle** cannot be built with a correct ABI on Linux, so
  it is built on a **GitHub Actions macOS runner** using Apple's toolchain. The
  workflow (`.github/workflows/build.yml`) installs Theos and a patched iOS 16.5
  SDK (for the private `Preferences` framework), builds with
  `make package FINALPACKAGE=1`, stamps the build number into the version, and
  checks the resulting Mach-O reports the versioned `arm64e` ABI (`caps 0x80`,
  `USR00`). See `docs/CI-ARM64E-BUILD.md`.
- The **daemon** is `arm64` and builds anywhere Theos runs.
- Releases are published to a **GPG-signed APT repo** at `https://ymuu.me/repo`,
  hosted as static files from the MainBlog site. `scripts/publish-repo.sh` (kept
  local) rebuilds and signs the repo from a `.deb`.

## Design notes

- **Two processes, no linking.** The panel writes intent; the daemon enforces it.
  This keeps the privileged code small and lets the UI evolve independently.
- **Interface-based Wi-Fi selection** is deliberate: service names vary by device
  and carrier, but the interface hardware type is stable.
- **`activeProxy` as the single source of truth** for what the daemon applies
  means the profiles list is purely a UI convenience layered on top.
