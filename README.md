<p align="center">
  <img src="icon.png" width="120" height="120" alt="ProxySwitcher-ng icon" />
</p>

<h1 align="center">ProxySwitcher-ng</h1>

<p align="center">
  Flip your iPhone's Wi-Fi proxy on and off from Settings, and keep a list of
  proxies you can switch between with one tap.
</p>

<p align="center">
  <img src="./demo.gif" width="900" alt="ProxySwitcher-ng demo" />
</p>

---

Made for the times you want your phone's traffic going through Burp, mitmproxy,
or any other intercepting proxy, without digging through the stock Wi-Fi settings
every time. Set your proxies once, then flip between them.

## What it does

- **One switch.** Turn the Wi-Fi HTTP/HTTPS proxy on or off from a single toggle.
- **HTTP or SOCKS.** Each proxy can be HTTP/HTTPS or SOCKS5, chosen per profile
  with a simple switch. Point your phone at a SOCKS tunnel (`ssh -D`, mitmproxy
  `--mode socks5`, and the like) or a regular HTTP intercept proxy.
- **Saved profiles.** Keep a list of proxies (`host:port`) and tap to make one
  active. Add, edit, and delete them right in Settings, no SSH needed. Edit an
  existing profile to flip it between HTTP and SOCKS without recreating it.
- **Sticks around.** A small root daemon re-applies your proxy when you switch
  Wi-Fi networks, so it does not fall off on you.
- **Apply and check, for real.** The Apply button actually routes a request
  through the proxy to a test host and reports back. It speaks the proxy's own
  protocol (HTTP `CONNECT`, or the SOCKS5 handshake), so it cannot be fooled by
  iOS silently falling back to a direct connection, and a failure shows the
  specific reason (connection refused, timeout, SOCKS reply code, HTTP status).
- **Logs when you want them.** Turn on logging to see exactly what the daemon did,
  readable from a Logs page inside the app.

## Install

Add the repo to Sileo, then search for **ProxySwitcher-ng**:

```
https://ymuu.me/repo
```

Or open this link on your device:

<https://ymuu.me/repo>

Works on rootless and roothide jailbreaks (Dopamine and similar), iOS 15 and up.
After installing, respring when Sileo offers.

## How it works

```
Settings (ProxySwitcher-ng panel)
   writes prefs, posts a Darwin notification
        v
proxyswitcherngd (root daemon)
   reads the active proxy, writes the Wi-Fi service's proxy keys
        v
SystemConfiguration commit + apply
```

The Settings panel is a compiled arm64e preference bundle. The daemon is a
standalone arm64 launch daemon. They talk over a shared prefs domain
(`io.ymuu.proxyswitcherng`) and Darwin notifications.

## Building

The arm64e preference bundle is built on a macOS GitHub Actions runner, since a
correct arm64e ABI needs Apple's toolchain. Push a branch and the workflow builds
and uploads the `.deb`. See `docs/CI-ARM64E-BUILD.md` for the details and the
potholes.

## Changelog

### Unreleased

- **SOCKS5 support.** Each profile can now be HTTP/HTTPS or SOCKS5, chosen with a
  per-profile switch, plus a switch for the manual entry. The daemon writes the
  Wi-Fi service's SOCKS keys or HTTP/HTTPS keys accordingly and never leaves both
  set at once.
- **Real end-to-end Apply check.** Apply now reaches a test host through the proxy
  using the proxy's own protocol (HTTP `CONNECT` / SOCKS5), instead of only
  checking that the proxy port is open. Failures report the specific reason.
- **Universal build.** The preference bundle now ships both arm64 and arm64e
  slices, so it loads on A11 and older devices (iPhone 8 / X) as well as A12+.

### Earlier

- Saved proxy profiles (add, edit, delete, select) from Settings.
- Single on/off toggle, logging console with a Logs page, per-build versioning,
  Settings icon, signed Sileo repo.

## Credit

A modern rewrite of [mikaelbo/ProxySwitcher](https://github.com/mikaelbo/ProxySwitcher),
the original iOS 9 tweak. Same idea, rebuilt for modern rootless and roothide
jailbreaks, with saved profiles and a few extras.

## License

See the upstream project for its license. This rewrite is shared for research and
personal use.
