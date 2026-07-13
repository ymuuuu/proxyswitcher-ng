export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += proxyswitcherd
SUBPROJECTS += prefs


include $(THEOS)/makefiles/aggregate.mk
