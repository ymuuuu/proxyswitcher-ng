TARGET := iphone:clang:latest:15.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ProxySwitcherNG

ProxySwitcherNG_FILES = MBRootListController.m
ProxySwitcherNG_FRAMEWORKS = UIKit
ProxySwitcherNG_PRIVATE_FRAMEWORKS = Preferences
ProxySwitcherNG_INSTALL_PATH = /Library/PreferenceBundles
ProxySwitcherNG_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
