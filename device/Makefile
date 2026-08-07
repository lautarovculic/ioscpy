export ARCHS = arm64 arm64e
# The product target is iPhone 14 Pro on iOS 16.0.2. VideoToolbox's modern
# pixel-transfer session is SDK-declared iOS 16+, so keep deployment aligned
# with the supported device instead of carrying dead iOS 14 compatibility.
export TARGET = iphone:clang:latest:16.0

include $(THEOS)/makefiles/common.mk

SUBPROJECTS = daemon ctl tweak

include $(THEOS)/makefiles/aggregate.mk
