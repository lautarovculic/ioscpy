#import "DisplayController.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL gRemoteBlack = NO;
static BOOL gUsedFullOff = NO;

static id sharedObject(const char *name) {
    Class cls = objc_getClass(name);
    if (!cls) return nil;
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if ([(id)cls respondsToSelector:shared]) {
        return ((id (*)(id, SEL))objc_msgSend)((id)cls, shared);
    }
    return nil;
}

static BOOL setFullDisplayPower(BOOL on) {
    id controller = sharedObject("SBBacklightController");
    if (!controller) return NO;
    SEL selector = NSSelectorFromString(on
        ? @"turnOnScreenFullyWithBacklightSource:"
        : @"turnOffScreenFullyWithBacklightSource:");
    if ([controller respondsToSelector:selector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(controller, selector, 1);
        return YES;
    }
    return NO;
}

static BOOL setBacklightFactor(float factor) {
    id controller = sharedObject("SBBacklightController");
    if (!controller) return NO;
    SEL selector = NSSelectorFromString(@"setBacklightFactor:source:");
    if ([controller respondsToSelector:selector]) {
        ((void (*)(id, SEL, float, NSInteger))objc_msgSend)(controller, selector, factor, 1);
        return YES;
    }
    selector = NSSelectorFromString(@"_setBacklightFactor:source:");
    if ([controller respondsToSelector:selector]) {
        ((void (*)(id, SEL, float, NSInteger))objc_msgSend)(controller, selector, factor, 1);
        return YES;
    }
    return NO;
}

BOOL IOSPYSetRemoteBlackScreen(BOOL enabled) {
    __block BOOL result = NO;
    void (^work)(void) = ^{
        if (enabled == gRemoteBlack) {
            result = YES;
            return;
        }
        if (enabled) {
            // Keep SpringBoard and the foreground app active while only the
            // physical panel is turned off. Capture/encode remain session-owned.
            UIApplication.sharedApplication.idleTimerDisabled = YES;
            gUsedFullOff = setFullDisplayPower(NO);
            result = gUsedFullOff || setBacklightFactor(0.0f);
            if (result) {
                gRemoteBlack = YES;
                NSLog(@"[ioscpyhook] remote black screen enabled mode=%@",
                      gUsedFullOff ? @"full-off" : @"factor-zero");
            }
        } else {
            BOOL powered = setFullDisplayPower(YES);
            BOOL factor = setBacklightFactor(1.0f);
            UIApplication.sharedApplication.idleTimerDisabled = NO;
            result = powered || factor;
            gRemoteBlack = NO;
            gUsedFullOff = NO;
            NSLog(@"[ioscpyhook] remote black screen disabled");
        }
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return result;
}

BOOL IOSPYRemoteBlackScreenEnabled(void) {
    return gRemoteBlack;
}

void IOSPYRestoreDisplayForLocalInput(void) {
    if (gRemoteBlack) {
        IOSPYSetRemoteBlackScreen(NO);
    }
}
