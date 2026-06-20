TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = ioscpyd

ioscpyd_FILES = main.mm ControlServer.mm FrameStore.mm FrameIngest.mm Protocol.mm ../jbcompat/Detect.mm ../jbcompat/Paths.mm
ioscpyd_CFLAGS = -fobjc-arc -I../jbcompat -Wno-deprecated-declarations
ioscpyd_FRAMEWORKS = Foundation
ioscpyd_CODESIGN_FLAGS = -Sentitlements.plist
ioscpyd_INSTALL_PATH = /usr/bin

include $(THEOS)/makefiles/tool.mk
