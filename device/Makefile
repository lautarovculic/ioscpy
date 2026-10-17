export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_WITHOUT_LIBROOT = 1

include $(THEOS)/makefiles/common.mk

SUBPROJECTS = daemon ctl tweak

include $(THEOS)/makefiles/aggregate.mk
