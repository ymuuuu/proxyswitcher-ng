# Features

Everything ProxySwitcher-ng does today, and what is on the roadmap.

## Shipped

### Proxy control
- **One-switch toggle.** A single `Enabled` switch turns the Wi-Fi HTTP and HTTPS
  proxy on or off. No separate "mode" toggle to get confused by.
- **Manual server and port.** Set a proxy `Server` and `Port` by hand.
- **Apply and verify.** An `Apply` button in the panel re-pushes the current
  setting to the daemon, then runs a quick connectivity check
  (`captive.apple.com`) and tells you whether the phone can still reach the
  internet through the proxy.

### Saved profiles
- **Named profiles.** Keep a list of proxies, each stored as `name` plus a
  `host:port` value.
- **Add, edit, delete in Settings.** Add a profile from the panel, swipe a row to
  edit or delete it. No SSH or file editing needed.
- **One-tap select.** Tap a profile to make it active. The active profile shows a
  checkmark. Selecting one writes `activeProxy`, which overrides the manual
  server and port.
- **Input validation.** The profile editor requires a non-empty host and a port
  in the range 1 to 65535.

### Reliability
- **Sticks across Wi-Fi switches.** A root daemon re-applies the proxy whenever
  the network changes, so it does not fall off when you move between networks.
- **Wi-Fi service picked by interface.** The daemon selects the Wi-Fi service by
  its interface (`Hardware == AirPort`, falling back to `Type == IEEE80211`)
  rather than by name, which is fragile.
- **Idempotent, crash-safe writes.** The port is coerced to a number before it
  reaches SystemConfiguration, and proxy fields are compared with strict type
  checks. If nothing changed, nothing is written, so re-applying is safe.

### Diagnostics
- **Optional logging.** An `Enable logging` switch makes the daemon append
  timestamped lines to a log file describing what it read and what it applied.
- **Logs page.** A `Logs` screen inside the panel shows the log, with `Refresh`
  and `Clear`. Clearing is delegated to the daemon (the log file is root-owned).

### Packaging and distribution
- **Version and build in the panel.** An `About` footer shows the version and the
  CI build number, so you always know which build you are on.
- **Per-build versioning.** CI stamps the package `Version` and the bundle
  `CFBundleVersion` from the build number.
- **App icon.** The panel carries the project icon.
- **Rootless and roothide.** Built for modern jailbreaks (Dopamine and similar),
  iOS 15 and up.
- **Signed Sileo repo.** Distributed from a GPG-signed APT repo at
  `https://ymuu.me/repo`.

## Roadmap

Considered and deliberately deferred or skipped:

- **Status-bar toggle** (tap an icon in the status bar to flip the proxy).
  Skipped for now: cramped on notched devices, and the maintenance cost is high
  for a convenience shortcut. A URL-scheme or Activator toggle is a lighter
  alternative if a quick toggle is wanted later.
- **Proxy authentication** (username and password), and auto-filling the system
  proxy login prompt. Not built yet. Useful against authenticated proxies.
- **Support links** in the panel (contact, source). Trivial, not added yet.

The upstream project's own wishlist item, "multiple proxy configurations", is
already done here as the saved profiles feature.
