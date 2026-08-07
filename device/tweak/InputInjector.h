// Privileged interaction: inject synthesized touches and trigger system actions.
// Coordinates arrive normalized to [0, 1] of the screen so the host stays
// resolution and orientation independent. This side maps them to the device.

#import <Foundation/Foundation.h>

typedef NS_ENUM(uint8_t, IOSPYTouchPhase) {
    IOSPYTouchDown = 0,
    IOSPYTouchMove = 1,
    IOSPYTouchUp = 2,
};

#ifdef __cplusplus
extern "C" {
#endif

// Inject a single-finger touch at normalized (x, y) in [0, 1]. Returns YES when
// the event was constructed and submitted to an available HID route. This is a
// submission acknowledgement; private IOHID APIs do not report whether the
// foreground application ultimately consumed the event.
BOOL IOSPYInjectTouch(IOSPYTouchPhase phase, uint8_t fingerID, float x, float y);

// Dedicated serial USER_INTERACTIVE queue for HID event construction/dispatch.
// Network input must not wait behind SpringBoard's UIKit main runloop; callers
// that need synchronous timing telemetry can dispatch their work on this queue.
dispatch_queue_t IOSPYInputRealtimeQueue(void);

// Convert AppKit wheel/trackpad deltas into a continuously sampled synthetic
// pan gesture. The internal 120 Hz integrator smooths coarse mouse-wheel
// notches and preserves trackpad momentum without requiring the user to drag.
void IOSPYInjectScroll(uint8_t phase, uint8_t momentumPhase, BOOL precise,
                       float deltaX, float deltaY, float x, float y);

// Initialize HID routing and the physical-touch sender monitor when SpringBoard
// loads the tweak, before the first remote input arrives.
void IOSPYInputInit(void);

// Best-effort runtime diagnostics included in periodic stream telemetry.
NSDictionary *IOSPYInputDiagnostics(void);

// Trigger a system action (codes match the host: 1=Home, 2=Lock, 3=Wake,
// 4=AppSwitcher, 5=RotateLeft, 6=RotateRight, 7=Screenshot, 8=Back).
void IOSPYSystemAction(uint16_t action);

// Type a run of text into the focused field of the foreground app. The Mac has
// already resolved its layout, so these are the literal characters to enter.
void IOSPYTypeText(NSString *text);

// A non-text key / editing action (codes match the host KeyCode enum:
// 1=Enter 2=Backspace 3=Tab 4=Escape 5=Left 6=Right 7=Up 8=Down,
// 10=SelectAll 11=Copy 12=Paste 13=Cut 14=Undo).
void IOSPYKeyAction(uint8_t code);

// Wake and enter a numeric passcode only when SpringBoard reports that the UI is
// locked. It never types into a foreground application and never bypasses the
// system passcode check.
void IOSPYUnlockWithPasscode(NSString *passcode);

// Begin tracking the foreground app's orientation (polled on the main thread).
void IOSPYOrientationStart(void);

// The current foreground orientation: 1=portrait, 2=upsideDown, 3=landscapeLeft,
// 4=landscapeRight. Safe to read off the main thread.
int IOSPYCurrentOrientation(void);

#ifdef __cplusplus
}
#endif
