TARGET = iphone:clang:latest:16.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ioscpyhook

ioscpyhook_FILES = Tweak.xm Capture.mm StreamClient.mm Encoder.mm InputInjector.mm KeyboardSuppression.mm PairingOverlay.mm DisplayController.mm AudioCapture.mm ../daemon/Protocol.mm
ioscpyhook_CFLAGS = -fobjc-arc -I../daemon
ioscpyhook_FRAMEWORKS = Foundation UIKit ImageIO CoreGraphics IOSurface QuartzCore IOKit VideoToolbox CoreMedia CoreVideo ReplayKit AudioToolbox AVFoundation

include $(THEOS)/makefiles/tweak.mk
