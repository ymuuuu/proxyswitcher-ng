# Pin the SDK to 16.5 so theos uses the patched $THEOS/sdks copy (which ships
# PrivateFrameworks/Preferences.tbd). `latest` would resolve to Xcode's public
# SDK, which has no PrivateFrameworks -> "framework 'Preferences' not found".
# The arm64e ABI 0x80 comes from Xcode's clang/ld64 (via xcrun), not the SDK.
TARGET := iphone:clang:16.5:15.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ProxySwitcherNG

ProxySwitcherNG_FILES = PSNRootListController.m PSNProfileEditController.m PSNLogsController.m
ProxySwitcherNG_FRAMEWORKS = UIKit
ProxySwitcherNG_PRIVATE_FRAMEWORKS = Preferences
ProxySwitcherNG_INSTALL_PATH = /Library/PreferenceBundles
ProxySwitcherNG_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
