#import "KeyboardSuppression.h"

#import <dlfcn.h>
#import <notify.h>

// GraphicsServices owns the system-wide "a hardware keyboard is attached" flag.
// Every app reads it to decide whether to draw the software keyboard, so setting
// it once hides the keyboard everywhere. We resolve it at runtime. It's a system
// framework present on every layout, but we never hard-link a private symbol.
static BOOL gAvailable = NO;
static BOOL gActive = NO;          // are WE currently hiding the keyboard?
static BOOL gPriorAttached = NO;   // was a real keyboard attached when we started?

static void (*sSet2)(Boolean, uint8_t) = NULL;
static void (*sSet3)(Boolean, uint8_t, uint8_t) = NULL;
static Boolean (*sIs)(void) = NULL;

static void applyAttached(BOOL attached) {
    if (sSet3) {
        sSet3(attached, 0, 0);
    } else if (sSet2) {
        sSet2(attached, 0);
    }
    // Nudge apps that registered late to re-read the flag.
    notify_post("GSEventHardwareKeyboardAvailabilityChanged");
}

void IOSPYKeyboardSuppressionInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The hardware-keyboard mode that hides the software keyboard is iOS 16+.
        NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
        if (v.majorVersion < 16) {
            return; // iOS 15 and earlier: nothing to do
        }
        void *gs = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/"
                          "GraphicsServices",
                          RTLD_LAZY);
        if (!gs) {
            return;
        }
        sSet3 = (void (*)(Boolean, uint8_t, uint8_t))dlsym(
            gs, "GSEventSetHardwareKeyboardAttachedWithCountryCodeAndType");
        sSet2 = (void (*)(Boolean, uint8_t))dlsym(gs, "GSEventSetHardwareKeyboardAttached");
        sIs = (Boolean (*)(void))dlsym(gs, "GSEventIsHardwareKeyboardAttached");
        gAvailable = (sSet3 != NULL || sSet2 != NULL);

        // Fresh SpringBoard with no ioscpy session yet: clear any stale hidden
        // state a crashed previous instance could have left, so the device never
        // boots keyboard-less. (A real keyboard is re-detected by the system right
        // after, so this doesn't fight one.)
        if (gAvailable) {
            gActive = NO;
            gPriorAttached = NO;
            applyAttached(NO);
        }
    });
}

void IOSPYSetKeyboardSuppressed(BOOL on) {
    if (!gAvailable || on == gActive) {
        return;
    }
    if (on) {
        gPriorAttached = (sIs != NULL) ? (BOOL)sIs() : NO; // don't fight a real keyboard
        gActive = YES;
        applyAttached(YES);
        NSLog(@"[ioscpyhook] software keyboard hidden");
    } else {
        gActive = NO;
        if (!gPriorAttached) {
            applyAttached(NO); // restore only what we changed
            NSLog(@"[ioscpyhook] software keyboard restored");
        }
    }
}
