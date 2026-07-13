export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += proxyswitcherd


include $(THEOS)/makefiles/aggregate.mk
