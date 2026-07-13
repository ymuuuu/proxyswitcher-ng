include $(THEOS)/makefiles/common.mk

TOOL_NAME = proxyswitcherngd
# Standalone daemon: build armv8.0 (arm64), NOT arm64e. The Linux theos clang
# emits arm64e with the legacy ptrauth ABI (caps 0x00), which the A12+ kernel
# refuses to exec ("Bad CPU type in executable"). A plain arm64 process is not
# injected into an arm64e host, so it has no arm64e requirement and runs fine.
proxyswitcherngd_ARCHS = arm64
proxyswitcherngd_FILES = main.m MBWiFiProxyHandler.m
proxyswitcherngd_FRAMEWORKS = Foundation SystemConfiguration
proxyswitcherngd_CODESIGN_FLAGS = -Sentitlements.plist
proxyswitcherngd_INSTALL_PATH = /usr/bin
ADDITIONAL_OBJCFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tool.mk
