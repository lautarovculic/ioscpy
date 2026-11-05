TARGET = iphone:clang:latest:15.0
ARCHS = arm64
THEOS_WITHOUT_LIBROOT = 1
include $(THEOS)/makefiles/common.mk

TOOL_NAME = capture-probe
capture-probe_FILES = capture_probe.mm ../tweak/Encoder.mm
capture-probe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
capture-probe_FRAMEWORKS = Foundation UIKit QuartzCore CoreGraphics IOSurface ImageIO MobileCoreServices VideoToolbox CoreMedia CoreVideo
capture-probe_CODESIGN_FLAGS = -Sentitlements.plist
include $(THEOS)/makefiles/tool.mk
