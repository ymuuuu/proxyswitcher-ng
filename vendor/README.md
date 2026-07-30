# Vendored dependencies

## hev-socks5-tunnel

- Upstream: https://github.com/heiher/hev-socks5-tunnel (MIT, see `hev-socks5-tunnel/LICENSE`)
- Pinned commit: 180cda8b304b71b9d9ef8ea93aeb0e4e00e15f7d
- Submodules expanded in place (SHAs from `git submodule status`):
  - `src/core`                  -> https://github.com/heiher/hev-socks5-core @ 162dd996299fc2d2bff2dd63728f8a2cd71ed31a
  - `third-part/hev-task-system`-> https://github.com/heiher/hev-task-system @ 328f35d903221b51811b3d02b277d665dfbdc75f
  - `third-part/yaml`           -> https://github.com/heiher/yaml @ efa36117a8646d26d12b58e05bac472d7854a70d
  - `third-part/lwip`           -> https://github.com/heiher/lwip @ 2a11c14c7a32887af25a034e82ef18b0b12076ac (FORK - has Apple netif
    flags upstream lwIP lacks; do not replace with stock lwIP)
- Vendored: 2026-07-30

Used as the userspace TCP/IP stack for tunnel mode. Entered via
`hev_socks5_tunnel_main(config_path, tun_fd)` (blocking; accepts our utun fd),
stopped with `hev_socks5_tunnel_quit()` from another thread. Public header:
`src/hev-main.h`. Config schema source of truth: `conf/main.yml` in the
vendored tree - if it disagrees with anything else, it wins.

Do not edit in place. To update: re-clone at the new commit with
`git clone --recursive`, replace this tree, update the SHAs above.

Build notes (see `proxyswitcherd/Makefile`):
- `proxyswitcherngd_USE_MODULES = 0`: lwIP deliberately redefines SDK netinet
  structs (`struct ip6_hdr`, `struct icmp6_hdr`); clang `-fmodules` ODR-checks
  them against the SDK module and fails. Upstream builds without modules.
- `-DYAML_VERSION_*`: the yaml fork takes its version macros from its
  `configs.mk` as `-D` flags; they are not in `yaml.h`.
- `filter-out` of `third-part/hev-task-system/src/lib/list/hev-list.c` and
  `.../lib/rbtree/hev-rbtree.c`: identical copies (modulo copyright header) of
  `src/misc/hev-list.c` and `src/core/src/hev-rbtree.c`. Upstream's per-library
  static archives tolerate the duplicates; a direct object link does not.
