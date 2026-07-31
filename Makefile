export THEOS_PACKAGE_SCHEME = rootless

# The dpkg architecture tag for the built package. This must be set here, not
# only in ./control: theos evaluates $(THEOS_PROJECT_DIR)/control before
# THEOS_PROJECT_DIR is populated, so the wildcard misses, the Architecture
# field in control is never read, and the package falls back to
# iphoneos-arm64. `override` is what survives package.mk clearing the variable.
#
# It matters because a rootless jailbreak on A12+ is iphoneos-arm64e: with the
# arm64 tag, `dpkg -i` refuses the package outright, and --force-architecture
# leaves an unsatisfiable preferenceloader:iphoneos-arm64 dependency that
# blocks apt entirely until it is removed by hand. Sileo hides this with its
# own arch patcher, which is why it went unnoticed until a manual install.
#
# This is packaging metadata only. It does not change what is compiled: the
# daemon stays arm64-only (see proxyswitcherd/Makefile) and the prefs bundle
# stays fat arm64 + arm64e (see prefs/Makefile).
override THEOS_PACKAGE_ARCH := iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += proxyswitcherd
SUBPROJECTS += prefs


include $(THEOS)/makefiles/aggregate.mk
