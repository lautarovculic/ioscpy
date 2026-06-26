#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <signal.h>

#import "StreamClient.h"
#import "InputInjector.h"
#import "KeyboardSuppression.h"

// Injected into SpringBoard. Announces itself on load and starts the stream
// client, which connects to the daemon and captures the screen on demand.

// SpringBoard's proxy for an app-requested system alert. Declared so we can
// resolve the cross-app paste confirmation without showing it. We only ever
// message it after confirming the class and selectors at runtime.
@interface SBUserNotificationAlert : NSObject
- (void)_setActivated:(BOOL)activated;
- (void)_sendResponseAndCleanUp:(BOOL)cleanup;
@end

// Only true on iOS 16+, where the blocking "… would like to paste from …" prompt
// exists. iOS 15 (and earlier) never created it, so this stays a clean no-op.
static BOOL gSuppressPasteAlert = NO;

// The cross-app paste confirmation is a SpringBoard-hosted alert presented for
// whatever process read the pasteboard, so suppressing it here covers clipboard
// sync in both directions. We touch ONLY the "pasted" alert; every other
// SpringBoard alert falls through untouched. Any mismatch fails open (the prompt
// just reappears) so a future iOS layout change can't wedge the alert pipe.
%hook SBAlertItem

+ (void)activateAlertItem:(id)arg1 {
    if (gSuppressPasteAlert && arg1) {
        Class cls = NSClassFromString(@"SBUserNotificationAlert");
        if (cls && [arg1 isKindOfClass:cls]) {
            NSString *source = nil;
            Ivar iv = class_getInstanceVariable(object_getClass(arg1), "_alertSource");
            if (iv) {
                @try {
                    source = object_getIvar(arg1, iv);
                } @catch (__unused id e) {
                    source = nil;
                }
            }
            if ([source isKindOfClass:[NSString class]] && [source isEqualToString:@"pasted"] &&
                [arg1 respondsToSelector:@selector(_setActivated:)] &&
                [arg1 respondsToSelector:@selector(_sendResponseAndCleanUp:)]) {
                [arg1 _setActivated:NO];
                [arg1 _sendResponseAndCleanUp:YES];
                return; // swallow it, the alert never appears
            }
        }
    }
    %orig(arg1);
}

%end

%ctor {
    @autoreleasepool {
        // SpringBoard must not die if the daemon/host side closes a socket while
        // the tweak is writing a frame or clipboard update.
        signal(SIGPIPE, SIG_IGN);

        NSString *process = [[NSProcessInfo processInfo] processName];
        NSLog(@"[ioscpyhook] loaded into %@ (v0.1.0)", process);

        // Leave a small breadcrumb others can stat to confirm the hook loaded.
        NSString *dir = @"/var/mobile/Library/Preferences";
        NSString *marker = [dir stringByAppendingPathComponent:@"com.ioscpy.hook.loaded"];
        [@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // The blocking paste prompt only exists on iOS 16+, so only arm the
        // suppression there; on iOS 15 it stays inert.
        NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
        gSuppressPasteAlert = (v.majorVersion >= 16);

        IOSPYOrientationStart();
        IOSPYKeyboardSuppressionInit();
        [[IOSPYStreamClient shared] start];
    }
}
