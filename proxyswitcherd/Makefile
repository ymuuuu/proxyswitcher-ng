include $(THEOS)/makefiles/common.mk

TOOL_NAME = proxyswitcherngd
# Standalone daemon: build armv8.0 (arm64), NOT arm64e. The Linux theos clang
# emits arm64e with the legacy ptrauth ABI (caps 0x00), which the A12+ kernel
# refuses to exec ("Bad CPU type in executable"). A plain arm64 process is not
# injected into an arm64e host, so it has no arm64e requirement and runs fine.
proxyswitcherngd_ARCHS = arm64
# Build without clang modules: lwIP deliberately redefines SDK netinet structs
# (struct ip6_hdr, struct icmp6_hdr), and -fmodules makes clang ODR-check them
# against the SDK module (2 hard errors in hev-config.c). Upstream builds with
# plain make (no modules), so the vendored C never expects them; none of our
# own sources use @import or need them either.
proxyswitcherngd_USE_MODULES = 0

# --- vendored hev-socks5-tunnel (see vendor/README.md) ---
# Same source sets upstream's own Makefiles build (root build.mk globs
# src/**.c, which includes src/core = hev-socks5-core; each third-part lib
# globs its own src/**). ENABLE_LIBRARY compiles out the CLI's main() in
# src/hev-main.c. Do not "tidy" the CONFIG_* defines: they come verbatim from
# hev-task-system/configs.mk and upstream's iOS build (build-apple.sh) uses
# exactly these.
rwildcard = $(foreach d,$(wildcard $1*),$(call rwildcard,$d/,$2) $(filter $(subst *,%,$2),$d))

HST := ../vendor/hev-socks5-tunnel
HST_C := $(call rwildcard,$(HST)/src/,*.c) \
         $(call rwildcard,$(HST)/third-part/lwip/src/,*.c) \
         $(call rwildcard,$(HST)/third-part/yaml/src/,*.c) \
         $(call rwildcard,$(HST)/third-part/hev-task-system/src/,*.c)
# Upstream links one static archive per library, where duplicate members are
# tolerated; we link objects directly, so the vendored COPIES of hev-list.c and
# hev-rbtree.c inside hev-task-system collide with the identical copies in
# src/misc and src/core (upstream's link order makes the latter win - diff
# shows the files are identical modulo copyright header). Drop the duplicates.
HST_C := $(filter-out $(HST)/third-part/hev-task-system/src/lib/list/hev-list.c \
                      $(HST)/third-part/hev-task-system/src/lib/rbtree/hev-rbtree.c,$(HST_C))
HST_S := $(call rwildcard,$(HST)/third-part/hev-task-system/src/,*.S)

HST_INC := -I$(HST)/src -I$(HST)/src/misc -I$(HST)/src/core/include \
           -I$(HST)/third-part/yaml/include \
           -I$(HST)/third-part/lwip/src/include -I$(HST)/third-part/lwip/src/ports/include \
           -I$(HST)/third-part/hev-task-system/include -I$(HST)/third-part/hev-task-system/src
# yaml's fork also takes its version macros from configs.mk as -D flags
# (YAML_VERSION_* are not in yaml.h; src/api.c fails without them).
HST_DEF := -DENABLE_LIBRARY \
           -DENABLE_STACK_OVERFLOW_DETECTION -DENABLE_MEMALLOC_SLICE -DENABLE_IO_SPLICE_SYSCALL \
           -DCONFIG_STACK_BACKEND=STACK_MMAP -DCONFIG_STACK_OVERFLOW_DETECTION=1 \
           -DCONFIG_MEMALLOC_SLICE_ALIGN=16 -DCONFIG_MEMALLOC_SLICE_MAX_SIZE=4096 \
           -DCONFIG_MEMALLOC_SLICE_MAX_COUNT=1000 -DCONFIG_SCHED_CLOCK=CLOCK_NONE \
           -DYAML_VERSION_MAJOR=0 -DYAML_VERSION_MINOR=2 -DYAML_VERSION_PATCH=5 \
           -DYAML_VERSION_STRING=\"0.2.5\"

proxyswitcherngd_FILES = main.m PSNWiFiProxyHandler.m PSNProxyRelay.m PSNCredentialStore.m \
                         PSNCredentialService.m PSNTunnelNet.c PSNTunnelDevice.m \
                         ../common/PSNProxyAuth.m ../common/PSNSocketUtil.m ../common/PSNCredIPC.m \
                         ../common/PSNLog.m ../common/PSNHostPort.m ../common/PSNPrefKeys.m \
                         ../common/PSNSNISniffer.m \
                         $(HST_C) $(HST_S)
proxyswitcherngd_FRAMEWORKS = Foundation SystemConfiguration Security
proxyswitcherngd_LDFLAGS = -lpthread
proxyswitcherngd_CODESIGN_FLAGS = -Sentitlements.plist
proxyswitcherngd_INSTALL_PATH = /usr/bin

# -I on BOTH: ADDITIONAL_CFLAGS does not feed Objective-C compilation
# (docs/PHASE0-UTUN-FINDINGS.md Part 4).
ADDITIONAL_OBJCFLAGS = -fobjc-arc -I../common $(HST_INC)
ADDITIONAL_CFLAGS    = -I../common $(HST_INC) $(HST_DEF) -std=gnu11

include $(THEOS_MAKE_PATH)/tool.mk
