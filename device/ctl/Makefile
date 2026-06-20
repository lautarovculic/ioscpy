TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = ioscpyctl

ioscpyctl_FILES = main.mm ../daemon/Protocol.mm ../jbcompat/Detect.mm ../jbcompat/Paths.mm
ioscpyctl_CFLAGS = -fobjc-arc -I../jbcompat -I../daemon -Wno-deprecated-declarations
ioscpyctl_FRAMEWORKS = Foundation
ioscpyctl_INSTALL_PATH = /usr/bin

include $(THEOS)/makefiles/tool.mk
