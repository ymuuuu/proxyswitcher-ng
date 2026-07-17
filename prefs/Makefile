# Pin the SDK to 16.5 so theos uses the patched $THEOS/sdks copy (which ships
# PrivateFrameworks/Preferences.tbd). `latest` would resolve to Xcode's public
# SDK, which has no PrivateFrameworks -> "framework 'Preferences' not found".
# The arm64e ABI 0x80 comes from Xcode's clang/ld64 (via xcrun), not the SDK.
#
# Build a fat bundle: arm64 for A11 and older (iPhone 8/X: Settings.app is arm64,
# has no arm64e slice), arm64e for A12+ (iPhone XS and newer). dyld picks the
# matching slice at load, so one .deb covers every device. The arm64e slice must
# carry Apple's ptrauth ABI (caps USR00), which only Xcode's clang/ld64 emit, so
# this MUST be built in CI on the macOS runner, never with Linux theos clang.
TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ProxySwitcherNG

ProxySwitcherNG_FILES = PSNRootListController.m PSNProfileEditController.m PSNLogsController.m PSNCredentialClient.m PSNProfileCell.m ../common/PSNProxyAuth.m ../common/PSNSocketUtil.m ../common/PSNCredIPC.m
ProxySwitcherNG_FRAMEWORKS = UIKit
ProxySwitcherNG_PRIVATE_FRAMEWORKS = Preferences
ProxySwitcherNG_INSTALL_PATH = /Library/PreferenceBundles
ProxySwitcherNG_CFLAGS = -fobjc-arc -I../common

include $(THEOS_MAKE_PATH)/bundle.mk
