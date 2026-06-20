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

// Inject a single-finger touch at normalized (x, y) in [0, 1].
void IOSPYInjectTouch(IOSPYTouchPhase phase, uint8_t fingerID, float x, float y);

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

// Begin tracking the foreground app's orientation (polled on the main thread).
void IOSPYOrientationStart(void);

// The current foreground orientation: 1=portrait, 2=upsideDown, 3=landscapeLeft,
// 4=landscapeRight. Safe to read off the main thread.
int IOSPYCurrentOrientation(void);

#ifdef __cplusplus
}
#endif
