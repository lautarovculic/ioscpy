#import "InputInjector.h"
#import "DisplayController.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_time.h>

// Private IOKit HID SPI, not in the public headers, so declared here. Touches are
// synthesized as digitizer events and dispatched through the system HID client.
// That only works from inside SpringBoard (the bundle identity is the
// authorization) and routes the event to whatever app is in the foreground.
typedef uint32_t IOHIDDigitizerTransducerType;
typedef double IOHIDFloat;
typedef uint32_t IOHIDEventField;
typedef uint32_t IOOptionBits;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDEventSystemConnection *IOHIDEventSystemConnectionRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

extern "C" {
IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator, uint64_t timeStamp,
                                             IOHIDDigitizerTransducerType type, uint32_t index,
                                             uint32_t identity, uint32_t eventMask,
                                             uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y,
                                             IOHIDFloat z, IOHIDFloat tipPressure,
                                             IOHIDFloat barrelPressure, Boolean range, Boolean touch,
                                             IOOptionBits options);
IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef allocator, uint64_t timeStamp,
                                                   uint32_t index, uint32_t identity,
                                                   uint32_t eventMask, IOHIDFloat x, IOHIDFloat y,
                                                   IOHIDFloat z, IOHIDFloat tipPressure,
                                                   IOHIDFloat twist, Boolean range, Boolean touch,
                                                   IOOptionBits options);
void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child);
void IOHIDEventSetIntegerValue(IOHIDEventRef e, IOHIDEventField f, int v);
void IOHIDEventSetFloatValue(IOHIDEventRef e, IOHIDEventField f, IOHIDFloat v);
void IOHIDEventSetSenderID(IOHIDEventRef e, uint64_t senderID);
uint64_t IOHIDEventGetSenderID(IOHIDEventRef e);
uint64_t IOHIDEventGetTimeStamp(IOHIDEventRef e);
uint32_t IOHIDEventGetType(IOHIDEventRef e);

IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef allocator, uint64_t timeStamp,
                                            uint32_t usagePage, uint32_t usage, Boolean down,
                                            IOOptionBits options);
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef, void *cb, void *target,
                                                 void *refcon);
}

#define kIOHIDDigitizerEventRange 0x00000001u
#define kIOHIDDigitizerEventTouch 0x00000002u
#define kIOHIDDigitizerEventPosition 0x00000004u
#define kIOHIDDigitizerEventIdentity 0x00000020u
#define kIOHIDDigitizerTransducerTypeHand 3
#define kIOHIDEventTypeDigitizer 11
#define kIOHIDEventTypeKeyboard 3

// Digitizer field selectors (same magic values long-used by touch tools).
#define kFieldDigitizerIsDisplayInteg 0x000b0019
#define kFieldDigitizerEventMask 0x000b0007
#define kFieldDigitizerRange 0x000b0008
#define kFieldDigitizerTouch 0x000b0009
#define kFieldDigitizerMajorRadius 0x000b0014
#define kFieldDigitizerMinorRadius 0x000b0015
#define kFieldEventBuiltIn 0x00000004

static uint64_t gSenderID = 0;
static BOOL gSenderFromRegistry = NO;
static IOHIDEventSystemClientRef gClient = NULL;
static IOHIDEventSystemClientRef gMonitor = NULL;
static IOHIDEventSystemConnectionRef gConnection = NULL;
typedef void (*IOSPYConnectionDispatchFn)(IOHIDEventSystemConnectionRef, IOHIDEventRef);
static IOSPYConnectionDispatchFn gConnectionDispatch = NULL;
static BOOL gRoutingInitialized = NO;
static volatile uint64_t gDispatchedEvents = 0;
static volatile uint64_t gDispatchFailures = 0;
static volatile uint64_t gTouchCommands = 0;
static volatile uint64_t gTouchSubmitted = 0;
static volatile uint64_t gTouchWithoutSender = 0;
// The physical HID monitor also sees synthetic events. Remember the exact
// timestamp before dispatch so black-screen mode only wakes for real local
// touch/button input, never for input sent by the Mac.
static volatile uint64_t gLastRemoteEventTimestamp = 0;
static volatile uint8_t gLastTouchPhase = 0xff;
static volatile float gLastTouchX = 0.0f;
static volatile float gLastTouchY = 0.0f;

static dispatch_queue_t inputRealtimeQueue(void) {
    static dispatch_queue_t queue = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        queue = dispatch_queue_create("com.ioscpy.hid-realtime", attr);
    });
    return queue;
}

dispatch_queue_t IOSPYInputRealtimeQueue(void) {
    return inputRealtimeQueue();
}

typedef CFArrayRef (*IOSPYCopyServicesFn)(IOHIDEventSystemClientRef);
typedef Boolean (*IOSPYServiceConformsFn)(IOHIDServiceClientRef, uint32_t, uint32_t);
typedef CFTypeRef (*IOSPYServiceRegistryIDFn)(IOHIDServiceClientRef);
typedef CFTypeRef (*IOSPYServiceCopyPropertyFn)(IOHIDServiceClientRef, CFStringRef);

// Resolve the built-in touch panel before the first physical touch. BackBoard's
// sender id for a HID service is its registry id; obtaining it here removes the
// old requirement to touch the phone once before remote input starts working.
// Every symbol is loaded dynamically because these service APIs moved between
// public/private header sets across iOS releases.
static void discoverDigitizerSenderID(IOHIDEventSystemClientRef client) {
    if (gSenderID != 0 || !client) {
        return;
    }
    IOSPYCopyServicesFn copyServices =
        (IOSPYCopyServicesFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
    IOSPYServiceConformsFn conforms =
        (IOSPYServiceConformsFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientConformsTo");
    IOSPYServiceRegistryIDFn registryID =
        (IOSPYServiceRegistryIDFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetRegistryID");
    IOSPYServiceCopyPropertyFn copyProperty =
        (IOSPYServiceCopyPropertyFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
    if (!copyServices || !conforms || !registryID) {
        return;
    }

    CFArrayRef services = copyServices(client);
    if (!services) {
        return;
    }
    uint64_t fallback = 0;
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef service =
            (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        // HID Digitizers page (0x0D), Touch Screen usage (0x04).
        if (!service || !conforms(service, 0x0D, 0x04)) {
            continue;
        }
        CFTypeRef value = registryID(service);
        uint64_t candidate = 0;
        if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &candidate);
        }
        if (candidate == 0) {
            continue;
        }
        if (fallback == 0) {
            fallback = candidate;
        }

        BOOL builtIn = NO;
        if (copyProperty) {
            CFTypeRef property = copyProperty(service, CFSTR("Built-In"));
            if (property) {
                if (CFGetTypeID(property) == CFBooleanGetTypeID()) {
                    builtIn = CFBooleanGetValue((CFBooleanRef)property);
                } else if (CFGetTypeID(property) == CFNumberGetTypeID()) {
                    int number = 0;
                    CFNumberGetValue((CFNumberRef)property, kCFNumberIntType, &number);
                    builtIn = number != 0;
                }
                CFRelease(property);
            }
        }
        if (builtIn) {
            gSenderID = candidate;
            break;
        }
    }
    if (gSenderID == 0) {
        gSenderID = fallback;
    }
    CFRelease(services);
    if (gSenderID != 0) {
        gSenderFromRegistry = YES;
        NSLog(@"[ioscpyhook] discovered digitizer senderID 0x%llx from HID registry",
              gSenderID);
    }
}

// Resolve SpringBoard's privileged event-routing connection dynamically. This
// route is accepted on systems where direct IOHIDEventSystemClient dispatch can
// silently discard synthetic digitizer events. Missing private classes or
// selectors simply leave us on the regular system-client path.
static void routingConnectionInit(void) {
    if (gRoutingInitialized) {
        return;
    }
    gRoutingInitialized = YES;
    gConnectionDispatch = (IOSPYConnectionDispatchFn)dlsym(
        RTLD_DEFAULT, "IOHIDEventSystemConnectionDispatchEvent");
    if (!gConnectionDispatch) {
        NSLog(@"[ioscpyhook] HID event-routing symbol unavailable; using system client");
        return;
    }
    Class accessibility = NSClassFromString(@"BKAccessibility");
    SEL managerSelector = NSSelectorFromString(@"_eventRoutingClientConnectionManager");
    if (!accessibility || ![(id)accessibility respondsToSelector:managerSelector]) {
        return;
    }
    id manager = ((id (*)(id, SEL))objc_msgSend)((id)accessibility, managerSelector);
    SEL clientSelector = NSSelectorFromString(@"clientForTaskPort:");
    if (!manager || ![manager respondsToSelector:clientSelector]) {
        return;
    }
    gConnection = ((IOHIDEventSystemConnectionRef (*)(id, SEL, mach_port_t))objc_msgSend)(
        manager, clientSelector, mach_task_self());
    if (gConnection && gConnectionDispatch) {
        NSLog(@"[ioscpyhook] HID event-routing connection ready");
    }
}

// Learn the real digitizer sender id from the first physical touch. Some builds
// drop injected events without it.
static void senderCallback(void *target, void *refcon, void *service, IOHIDEventRef event) {
    uint32_t type = IOHIDEventGetType(event);
    uint64_t timestamp = IOHIDEventGetTimeStamp(event);
    BOOL remote = timestamp != 0 && timestamp == gLastRemoteEventTimestamp;
    if (!remote && IOSPYRemoteBlackScreenEnabled() &&
        (type == kIOHIDEventTypeDigitizer || type == kIOHIDEventTypeKeyboard)) {
        IOSPYRestoreDisplayForLocalInput();
    }
    if (type == kIOHIDEventTypeDigitizer) {
        uint64_t sender = IOHIDEventGetSenderID(event);
        if (sender != 0 && sender != gSenderID) {
            gSenderID = sender;
            gSenderFromRegistry = NO;
            NSLog(@"[ioscpyhook] confirmed digitizer senderID 0x%llx from touch", gSenderID);
        }
    }
}

static void hidInit(void) {
    routingConnectionInit();
    if (!gClient) {
        gClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }
    if (!gClient && !gConnection) {
        NSLog(@"[ioscpyhook] no HID dispatch client is available (not in SpringBoard?)");
    }
    if (!gMonitor) {
        gMonitor = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }
    if (gMonitor) {
        discoverDigitizerSenderID(gMonitor);
        IOHIDEventSystemClientRegisterEventCallback(gMonitor, (void *)senderCallback, NULL, NULL);
        IOHIDEventSystemClientScheduleWithRunLoop(gMonitor, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    }
}

void IOSPYInputInit(void) {
    hidInit();
    NSLog(@"[ioscpyhook] input init route=%@ client=%d monitor=%d sender=0x%llx",
          gConnection ? @"event-connection" : (gClient ? @"system-client" : @"none"),
          gClient != NULL, gMonitor != NULL, gSenderID);
}

static BOOL dispatchHIDEvent(IOHIDEventRef event) {
    if (!event) {
        gDispatchFailures++;
        return NO;
    }
    gLastRemoteEventTimestamp = IOHIDEventGetTimeStamp(event);
    if (gConnection && gConnectionDispatch) {
        gConnectionDispatch(gConnection, event);
        gDispatchedEvents++;
        return YES;
    }
    if (gClient) {
        IOHIDEventSystemClientDispatchEvent(gClient, event);
        gDispatchedEvents++;
        return YES;
    }
    gDispatchFailures++;
    return NO;
}

NSDictionary *IOSPYInputDiagnostics(void) {
    NSString *route = gConnection ? @"event-connection" : (gClient ? @"system-client" : @"none");
    return @{
        @"route": route,
        @"client_ready": @((gClient != NULL) || (gConnection != NULL)),
        @"monitor_ready": @(gMonitor != NULL),
        @"sender_id": @(gSenderID),
        @"sender_source": gSenderID == 0 ? @"none" :
            (gSenderFromRegistry ? @"registry" : @"touch"),
        @"touch_commands": @(gTouchCommands),
        @"touch_submitted": @(gTouchSubmitted),
        @"touch_without_sender": @(gTouchWithoutSender),
        @"last_phase": @(gLastTouchPhase),
        @"last_x": @(gLastTouchX),
        @"last_y": @(gLastTouchY),
        @"dispatched_events": @(gDispatchedEvents),
        @"dispatch_failures": @(gDispatchFailures),
    };
}

// Rotate a normalized point into the panel's native-portrait space. The digitizer
// space does not rotate with the UI. orient: 1=portrait, 2=upsideDown,
// 3=landscapeLeft, 4=landscapeRight.
static void rotatePoint(int orient, float nx, float ny, float *rx, float *ry) {
    switch (orient) {
        case 3:  *rx = ny;        *ry = 1.0f - nx; break;
        case 4:  *rx = 1.0f - ny; *ry = nx;        break;
        case 2:  *rx = 1.0f - nx; *ry = 1.0f - ny; break;
        default: *rx = nx;        *ry = ny;        break;
    }
    *rx = fmaxf(0.0f, fminf(1.0f, *rx));
    *ry = fmaxf(0.0f, fminf(1.0f, *ry));
}

// Cached foreground-app orientation (1=portrait, 2=upsideDown, 3=landscapeLeft,
// 4=landscapeRight). Updated on the main thread (UIApplication is main-only).
// The off-main capture and touch paths just read this.
static volatile int gOrientation = 1;

// Map a UIInterfaceOrientation to our internal 1-4. Uses the enum constants so
// it's correct regardless of their raw numeric values.
static int mapInterfaceOrientation(NSInteger o) {
    switch (o) {
        case UIInterfaceOrientationPortrait:           return 1;
        case UIInterfaceOrientationPortraitUpsideDown: return 2;
        case UIInterfaceOrientationLandscapeLeft:      return 3;
        case UIInterfaceOrientationLandscapeRight:     return 4;
        default:                                       return 1;
    }
}

// Read the frontmost app's interface orientation. Must run on the main thread.
// activeInterfaceOrientation is SpringBoard's frontmost-app orientation across
// the versions we target. Fall back to the status bar orientation, then portrait,
// so an OS that lacks it just stays upright instead of failing.
static int readForegroundOrientation(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) {
        return 1;
    }
    // Resolve both selectors at runtime so the build doesn't trip on the
    // undeclared (private) one or the deprecated one.
    SEL active = NSSelectorFromString(@"activeInterfaceOrientation");
    if ([app respondsToSelector:active]) {
        NSInteger o = ((NSInteger (*)(id, SEL))objc_msgSend)(app, active);
        return mapInterfaceOrientation(o);
    }
    SEL bar = NSSelectorFromString(@"statusBarOrientation");
    if ([app respondsToSelector:bar]) {
        NSInteger o = ((NSInteger (*)(id, SEL))objc_msgSend)(app, bar);
        return mapInterfaceOrientation(o);
    }
    return 1;
}

void IOSPYOrientationStart(void) {
    static dispatch_source_t timer = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Poll on the main queue (UIApplication is main-thread only). Just a cheap
        // selector read a few times a second, never blocks the main thread.
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  (uint64_t)(0.4 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            int o = readForegroundOrientation();
            if (o >= 1 && o <= 4 && o != gOrientation) {
                gOrientation = o;
                NSLog(@"[ioscpyhook] orientation -> %d", o);
            }
        });
        dispatch_resume(timer);
    });
}

int IOSPYCurrentOrientation(void) {
    return gOrientation;
}

static int currentOrientation(void) {
    return gOrientation;
}

static int gTouchBalance = 0;
static uint64_t gTouchEpoch = 0;
static float gLastX = 0.5f;
static float gLastY = 0.5f;

BOOL IOSPYInjectTouch(IOSPYTouchPhase phase, uint8_t fingerID, float x, float y) {
    hidInit();
    gTouchCommands++;
    gLastTouchPhase = (uint8_t)phase;
    gLastTouchX = x;
    gLastTouchY = y;
    if (!gClient && !gConnection) {
        gDispatchFailures++;
        return NO;
    }

    gLastX = x;
    gLastY = y;
    if (phase == IOSPYTouchDown) {
        gTouchBalance++;
        gTouchEpoch++;
        // Safety net: if a swipe gets captured by a system edge gesture and no up
        // arrives, force one so the digitizer can't get stuck.
        uint64_t epoch = gTouchEpoch;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       inputRealtimeQueue(), ^{
            if (gTouchBalance > 0 && gTouchEpoch == epoch) {
                IOSPYInjectTouch(IOSPYTouchUp, 0, gLastX, gLastY);
            }
        });
    } else if (phase == IOSPYTouchUp) {
        if (gTouchBalance > 0) {
            gTouchBalance--;
        }
        gTouchEpoch++;
    }

    float rx, ry;
    rotatePoint(currentOrientation(), x, y, &rx, &ry);

    uint64_t ts = mach_absolute_time();
    Boolean touch = (phase != IOSPYTouchUp);
    Boolean range = touch;
    uint32_t mask = (phase == IOSPYTouchMove)
                        ? kIOHIDDigitizerEventPosition
                        : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);

    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, kIOHIDDigitizerTransducerTypeHand, 0, 0, mask, 0, 0, 0, 0, 0, 0,
        range, touch, 0);
    if (!parent) {
        gDispatchFailures++;
        return NO;
    }
    // BackBoard checks both the digitizer-specific integrated-display field and
    // the generic built-in field on recent iOS versions. The old implementation
    // only set the former, which can make a syntactically valid event get dropped.
    IOHIDEventSetIntegerValue(parent, kFieldDigitizerIsDisplayInteg, 1);
    IOHIDEventSetIntegerValue(parent, kFieldEventBuiltIn, 1);

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts, (uint32_t)fingerID, (uint32_t)fingerID + 1, mask,
        (IOHIDFloat)rx, (IOHIDFloat)ry, 0, touch ? 1.0 : 0.0, 0, range, touch, 0);
    if (!finger) {
        gDispatchFailures++;
        CFRelease(parent);
        return NO;
    }
    IOHIDEventSetFloatValue(finger, kFieldDigitizerMajorRadius, 0.04f);
    IOHIDEventSetFloatValue(finger, kFieldDigitizerMinorRadius, 0.04f);

    IOHIDEventAppendEvent(parent, finger);
    // What this event reports. A down/up announces a finger arriving or leaving
    // (range + touch, with its identity); a move announces a position change.
    // Re-asserting range+touch on every move makes each one read as a fresh
    // touch-begin, so a drag never coalesces into a continuous pan. Moves carry
    // the position bit instead, which is what lets swipes and scrolls track.
    uint32_t parentMask = (phase == IOSPYTouchMove)
                              ? kIOHIDDigitizerEventPosition
                              : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch |
                                 kIOHIDDigitizerEventIdentity);
    IOHIDEventSetIntegerValue(parent, kFieldDigitizerEventMask, parentMask);
    IOHIDEventSetIntegerValue(parent, kFieldDigitizerRange, range ? 1 : 0);
    IOHIDEventSetIntegerValue(parent, kFieldDigitizerTouch, touch ? 1 : 0);

    if (gSenderID != 0) {
        IOHIDEventSetSenderID(parent, gSenderID);
        IOHIDEventSetSenderID(finger, gSenderID);
    } else {
        // The privileged event-routing connection can accept sender-less events,
        // but the plain system-client path often cannot. Keep the attempt for
        // compatibility and surface the condition in telemetry instead of
        // silently reporting it as a confirmed touch.
        gTouchWithoutSender++;
    }

    BOOL submitted = dispatchHIDEvent(parent);
    if (submitted) {
        gTouchSubmitted++;
    }

    CFRelease(finger);
    CFRelease(parent);
    return submitted;
}

static dispatch_source_t gScrollTimer = NULL;
static BOOL gScrollActive = NO;
static float gScrollX = 0.5f;
static float gScrollY = 0.5f;
static float gScrollPendingX = 0;
static float gScrollPendingY = 0;
static CFAbsoluteTime gScrollLastInput = 0;

static float clampUnit(float value) {
    return fminf(0.97f, fmaxf(0.03f, value));
}

static void ensureScrollTimer(void) {
    if (gScrollTimer) {
        return;
    }
    gScrollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          inputRealtimeQueue());
    uint64_t interval = NSEC_PER_SEC / 120;
    dispatch_source_set_timer(gScrollTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval, interval / 4);
    dispatch_source_set_event_handler(gScrollTimer, ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        float magnitude = fabsf(gScrollPendingX) + fabsf(gScrollPendingY);
        if (!gScrollActive && magnitude > 0.0001f) {
            gScrollActive = YES;
            IOSPYInjectTouch(IOSPYTouchDown, 7, gScrollX, gScrollY);
        }
        if (gScrollActive && magnitude > 0.0001f) {
            // Exponential consumption gives coarse wheel notches a short, smooth
            // glide while precise trackpad deltas remain closely time-aligned.
            float stepX = gScrollPendingX * 0.32f;
            float stepY = gScrollPendingY * 0.32f;
            if (fabsf(stepX) < 0.00025f) stepX = copysignf(0.00025f, stepX);
            if (fabsf(stepY) < 0.00025f) stepY = copysignf(0.00025f, stepY);
            if (fabsf(stepX) > fabsf(gScrollPendingX)) stepX = gScrollPendingX;
            if (fabsf(stepY) > fabsf(gScrollPendingY)) stepY = gScrollPendingY;
            gScrollPendingX -= stepX;
            gScrollPendingY -= stepY;
            gScrollX = clampUnit(gScrollX + stepX);
            gScrollY = clampUnit(gScrollY + stepY);
            IOSPYInjectTouch(IOSPYTouchMove, 7, gScrollX, gScrollY);
        }
        if (gScrollActive && magnitude <= 0.0001f && now - gScrollLastInput > 0.075) {
            IOSPYInjectTouch(IOSPYTouchUp, 7, gScrollX, gScrollY);
            gScrollActive = NO;
            gScrollPendingX = 0;
            gScrollPendingY = 0;
        }
    });
    dispatch_resume(gScrollTimer);
}

void IOSPYInjectScroll(uint8_t phase, uint8_t momentumPhase, BOOL precise,
                       float deltaX, float deltaY, float x, float y) {
    dispatch_async(inputRealtimeQueue(), ^{
        ensureScrollTimer();
        gScrollLastInput = CFAbsoluteTimeGetCurrent();
        if (!gScrollActive && fabsf(gScrollPendingX) + fabsf(gScrollPendingY) < 0.0001f) {
            gScrollX = clampUnit(x);
            gScrollY = clampUnit(y);
        }
        // AppKit reports content-scrolling deltas; a synthetic finger must move
        // in the opposite direction to produce the same content motion.
        float factor = precise ? 0.0018f : 0.0075f;
        gScrollPendingX += -deltaX * factor;
        gScrollPendingY += deltaY * factor;
        gScrollPendingX = fminf(0.24f, fmaxf(-0.24f, gScrollPendingX));
        gScrollPendingY = fminf(0.24f, fmaxf(-0.24f, gScrollPendingY));

        BOOL cancelled = phase == 4 || momentumPhase == 4;
        if (cancelled && gScrollActive) {
            IOSPYInjectTouch(IOSPYTouchUp, 7, gScrollX, gScrollY);
            gScrollActive = NO;
            gScrollPendingX = 0;
            gScrollPendingY = 0;
        }
    });
}

// Press and release a HID button (e.g. the home button as consumer "menu").
static void injectButton(uint32_t usagePage, uint32_t usage) {
    hidInit();
    if (!gClient && !gConnection) {
        return;
    }
    for (int down = 1; down >= 0; down--) {
        IOHIDEventRef e = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                        usagePage, usage, down ? true : false, 0);
        if (!e) {
            continue;
        }
        if (gSenderID != 0) {
            IOHIDEventSetSenderID(e, gSenderID);
        }
        dispatchHIDEvent(e);
        CFRelease(e);
    }
}

// keyboard: HID keyboard page 0x07 routes to the foreground app's field

#define kHIDPage_Keyboard 0x07
#define kHIDUsage_LeftShift 0xE1
#define kHIDUsage_LeftGUI 0xE3

static void keyEvent(uint32_t usage, bool down) {
    hidInit();
    if (!gClient && !gConnection) {
        return;
    }
    IOHIDEventRef e = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                    kHIDPage_Keyboard, usage, down ? true : false, 0);
    if (!e) {
        return;
    }
    // Keyboard events route best with NO sender id (the captured one belongs to
    // the touch panel). Only set it if typing doesn't land during testing.
    dispatchHIDEvent(e);
    CFRelease(e);
}

// Press a key, optionally with Shift held, like a real keyboard chord.
static void typeUsage(uint32_t usage, bool shift) {
    if (shift) {
        keyEvent(kHIDUsage_LeftShift, true);
    }
    keyEvent(usage, true);
    keyEvent(usage, false);
    if (shift) {
        keyEvent(kHIDUsage_LeftShift, false);
    }
}

// Press a key with Command held (the iOS editing shortcuts).
static void cmdChord(uint32_t usage) {
    keyEvent(kHIDUsage_LeftGUI, true);
    keyEvent(usage, true);
    keyEvent(usage, false);
    keyEvent(kHIDUsage_LeftGUI, false);
}

// Map a US-ASCII character to its HID keyboard usage and whether Shift is needed.
static bool charToUsage(unichar c, uint32_t *usage, bool *shift) {
    *shift = false;
    if (c >= 'a' && c <= 'z') { *usage = 0x04 + (c - 'a'); return true; }
    if (c >= 'A' && c <= 'Z') { *usage = 0x04 + (c - 'A'); *shift = true; return true; }
    if (c >= '1' && c <= '9') { *usage = 0x1E + (c - '1'); return true; }
    if (c == '0') { *usage = 0x27; return true; }
    switch (c) {
        case ' ':  *usage = 0x2C; return true;
        case '\t': *usage = 0x2B; return true;
        case '\n': case '\r': *usage = 0x28; return true;
        case '!': *usage = 0x1E; *shift = true; return true;
        case '@': *usage = 0x1F; *shift = true; return true;
        case '#': *usage = 0x20; *shift = true; return true;
        case '$': *usage = 0x21; *shift = true; return true;
        case '%': *usage = 0x22; *shift = true; return true;
        case '^': *usage = 0x23; *shift = true; return true;
        case '&': *usage = 0x24; *shift = true; return true;
        case '*': *usage = 0x25; *shift = true; return true;
        case '(': *usage = 0x26; *shift = true; return true;
        case ')': *usage = 0x27; *shift = true; return true;
        case '-': *usage = 0x2D; return true;
        case '_': *usage = 0x2D; *shift = true; return true;
        case '=': *usage = 0x2E; return true;
        case '+': *usage = 0x2E; *shift = true; return true;
        case '[': *usage = 0x2F; return true;
        case '{': *usage = 0x2F; *shift = true; return true;
        case ']': *usage = 0x30; return true;
        case '}': *usage = 0x30; *shift = true; return true;
        case '\\': *usage = 0x31; return true;
        case '|': *usage = 0x31; *shift = true; return true;
        case ';': *usage = 0x33; return true;
        case ':': *usage = 0x33; *shift = true; return true;
        case '\'': *usage = 0x34; return true;
        case '"': *usage = 0x34; *shift = true; return true;
        case '`': *usage = 0x35; return true;
        case '~': *usage = 0x35; *shift = true; return true;
        case ',': *usage = 0x36; return true;
        case '<': *usage = 0x36; *shift = true; return true;
        case '.': *usage = 0x37; return true;
        case '>': *usage = 0x37; *shift = true; return true;
        case '/': *usage = 0x38; return true;
        case '?': *usage = 0x38; *shift = true; return true;
        default: return false;
    }
}

void IOSPYTypeText(NSString *text) {
    if (text.length == 0) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        hidInit();
        if (!gClient) {
            return;
        }
        NSUInteger n = text.length;
        for (NSUInteger i = 0; i < n; i++) {
            unichar c = [text characterAtIndex:i];
            uint32_t usage = 0;
            bool shift = false;
            if (charToUsage(c, &usage, &shift)) {
                typeUsage(usage, shift);
            }
            // Non-ASCII (accents, emoji) go through the clipboard-paste path.
        }
    });
}

void IOSPYKeyAction(uint8_t code) {
    dispatch_async(dispatch_get_main_queue(), ^{
        hidInit();
        if (!gClient) {
            return;
        }
        switch (code) {
            case 1:  typeUsage(0x28, false); break; // Enter
            case 2:  typeUsage(0x2A, false); break; // Backspace
            case 3:  typeUsage(0x2B, false); break; // Tab
            case 4:  typeUsage(0x29, false); break; // Escape
            case 5:  typeUsage(0x50, false); break; // Left
            case 6:  typeUsage(0x4F, false); break; // Right
            case 7:  typeUsage(0x52, false); break; // Up
            case 8:  typeUsage(0x51, false); break; // Down
            case 10: cmdChord(0x04); break;         // Cmd+A select all
            case 11: cmdChord(0x06); break;         // Cmd+C copy
            case 12: cmdChord(0x19); break;         // Cmd+V paste
            case 13: cmdChord(0x1B); break;         // Cmd+X cut
            case 14: cmdChord(0x1D); break;         // Cmd+Z undo
            default: break;
        }
    });
}

// system actions (run in SpringBoard, main thread)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

static void actionWake(void);

static id sharedOf(const char *cls) {
    Class c = objc_getClass(cls);
    if (!c) {
        return nil;
    }
    if ([c respondsToSelector:@selector(sharedInstance)]) {
        return [c performSelector:@selector(sharedInstance)];
    }
    if ([c respondsToSelector:@selector(sharedInstanceIfExists)]) {
        return [c performSelector:@selector(sharedInstanceIfExists)];
    }
    return nil;
}

void IOSPYUnlockWithPasscode(NSString *passcode) {
    if (passcode.length < 4 || passcode.length > 8) {
        NSLog(@"[ioscpyhook] refusing unlock passcode with invalid length");
        return;
    }
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([passcode rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        NSLog(@"[ioscpyhook] refusing non-numeric unlock passcode");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        id manager = sharedOf("SBLockScreenManager");
        BOOL locked = NO;
        SEL lockedSelector = NSSelectorFromString(@"isUILocked");
        if ([manager respondsToSelector:lockedSelector]) {
            locked = ((BOOL (*)(id, SEL))objc_msgSend)(manager, lockedSelector);
        } else {
            id cover = sharedOf("SBCoverSheetPresentationManager");
            SEL presented = NSSelectorFromString(@"isPresented");
            if ([cover respondsToSelector:presented]) {
                locked = ((BOOL (*)(id, SEL))objc_msgSend)(cover, presented);
            }
        }
        if (!locked) {
            NSLog(@"[ioscpyhook] auto-unlock skipped: device is not on the lock UI");
            return;
        }

        IOSPYRestoreDisplayForLocalInput();
        actionWake();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // Re-check immediately before typing. This is the guard that keeps a
            // delayed reconnect from entering the saved passcode into an app.
            BOOL stillLocked = YES;
            if ([manager respondsToSelector:lockedSelector]) {
                stillLocked = ((BOOL (*)(id, SEL))objc_msgSend)(manager, lockedSelector);
            }
            if (!stillLocked) {
                NSLog(@"[ioscpyhook] auto-unlock cancelled: lock state changed");
                return;
            }
            for (NSUInteger i = 0; i < passcode.length; i++) {
                unichar digit = [passcode characterAtIndex:i];
                uint32_t usage = digit == '0' ? 0x27 : (0x1E + (digit - '1'));
                typeUsage(usage, false);
            }
            // Some lock-screen layouts submit at the final digit, while others
            // accept Return. Sending Return after a short delay is harmless when
            // the final digit already completed the unlock.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ typeUsage(0x28, false); });
        });
    });
}

// Close Control Center / Notification Center if they're showing. The HID home
// button doesn't dismiss them on a no-home-button device.
static void dismissOverlays(void) {
    // Control Center.
    id cc = sharedOf("SBControlCenterController");
    if ([cc respondsToSelector:@selector(isPresented)] &&
        [cc respondsToSelector:@selector(dismissAnimated:)]) {
        BOOL (*shown)(id, SEL) = (BOOL (*)(id, SEL))[cc methodForSelector:@selector(isPresented)];
        if (shown(cc, @selector(isPresented))) {
            void (*fn)(id, SEL, BOOL) =
                (void (*)(id, SEL, BOOL))[cc methodForSelector:@selector(dismissAnimated:)];
            fn(cc, @selector(dismissAnimated:), YES);
        }
    }
    // Notification Center is the CoverSheet pulled down over an app, so dismiss it
    // by setting it un-presented.
    id cs = sharedOf("SBCoverSheetPresentationManager");
    SEL setSel = @selector(setCoverSheetPresented:animated:withCompletion:);
    if ([cs respondsToSelector:@selector(isPresented)] && [cs respondsToSelector:setSel]) {
        BOOL (*shown)(id, SEL) = (BOOL (*)(id, SEL))[cs methodForSelector:@selector(isPresented)];
        if (shown(cs, @selector(isPresented))) {
            void (*fn)(id, SEL, BOOL, BOOL, id) =
                (void (*)(id, SEL, BOOL, BOOL, id))[cs methodForSelector:setSel];
            fn(cs, setSel, NO, YES, nil);
        }
    }
}

static void actionHome(void) {
    // Close any pulled-down overlay first, then go home.
    dismissOverlays();
    injectButton(0x0C, 0x40);
}

static void actionLock(void) {
    id mgr = sharedOf("SBLockScreenManager");
    if ([mgr respondsToSelector:@selector(lockUIFromSource:withOptions:)]) {
        void (*fn)(id, SEL, long, id) =
            (void (*)(id, SEL, long, id))[mgr methodForSelector:@selector(lockUIFromSource:withOptions:)];
        fn(mgr, @selector(lockUIFromSource:withOptions:), 1, nil);
    }
}

static void actionWake(void) {
    id bl = sharedOf("SBBacklightController");
    if ([bl respondsToSelector:@selector(turnOnScreenFullyWithBacklightSource:)]) {
        void (*fn)(id, SEL, long) =
            (void (*)(id, SEL, long))[bl methodForSelector:@selector(turnOnScreenFullyWithBacklightSource:)];
        fn(bl, @selector(turnOnScreenFullyWithBacklightSource:), 1);
    } else if ([bl respondsToSelector:@selector(setBacklightFactor:source:)]) {
        void (*fn)(id, SEL, float, long) =
            (void (*)(id, SEL, float, long))[bl methodForSelector:@selector(setBacklightFactor:source:)];
        fn(bl, @selector(setBacklightFactor:source:), 1.0f, 1);
    }
}

static void actionAppSwitcher(void) {
    // SpringBoard's own handler for the "open app switcher" hardware-keyboard
    // shortcut. Closest match to what we want and present across recent iOS
    // releases. It ignores its sender, so nil is fine.
    id sb = [UIApplication sharedApplication];
    if ([sb respondsToSelector:@selector(_handleOpenAppSwitcherShortcut:)]) {
        [sb performSelector:@selector(_handleOpenAppSwitcherShortcut:) withObject:nil];
        return;
    }
    // Older layouts kept the switcher on dedicated controllers.
    id sw = sharedOf("SBMainSwitcherViewController");
    if ([sw respondsToSelector:@selector(activateSwitcherNoninteractively)]) {
        [sw performSelector:@selector(activateSwitcherNoninteractively)];
        return;
    }
    if ([sw respondsToSelector:@selector(activateSwitcher)]) {
        [sw performSelector:@selector(activateSwitcher)];
        return;
    }
    id uic = sharedOf("SBUIController");
    if ([uic respondsToSelector:@selector(_toggleSwitcher)]) {
        [uic performSelector:@selector(_toggleSwitcher)];
    }
}

// "Back". Cmd+[ is the most reliable trigger: UIKit registers it as the
// UINavigationController pop and WebKit/Safari as web-back, and it routes to the
// focused foreground app like a real keyboard, so it works cross-process from
// SpringBoard with no touch senderID (no first physical tap needed). Apps with a
// fully custom navigation stack respond to neither this nor a swipe, which is the
// realistic ceiling. We don't also fire an edge-swipe, which would double-back
// wherever both are honored.
static void actionBack(void) {
    cmdChord(0x2F); // Cmd+[
}

void IOSPYSystemAction(uint16_t action) {
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (action) {
            case 1: actionHome(); break;
            case 2: actionLock(); break;
            case 3: actionWake(); break;
            case 4: actionAppSwitcher(); break;
            case 8: actionBack(); break;
            default: NSLog(@"[ioscpyhook] unhandled system action %u", action); break;
        }
    });
}

#pragma clang diagnostic pop
