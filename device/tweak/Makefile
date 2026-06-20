TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ioscpyhook

ioscpyhook_FILES = Tweak.xm Capture.mm StreamClient.mm Encoder.mm InputInjector.mm KeyboardSuppression.mm ../daemon/Protocol.mm
ioscpyhook_CFLAGS = -fobjc-arc -I../daemon
ioscpyhook_FRAMEWORKS = Foundation UIKit ImageIO MobileCoreServices CoreGraphics IOSurface QuartzCore IOKit VideoToolbox CoreMedia CoreVideo

include $(THEOS)/makefiles/tweak.mk
