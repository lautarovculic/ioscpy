// Runtime detection of the jailbreak environment: layout, injection framework,
// and a few device facts. Kept in one place so nothing else has to special-case
// a given jailbreak.

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, IOSPYLayout) {
    IOSPYLayoutUnknown = 0,
    IOSPYLayoutRootless,
    IOSPYLayoutRootful,
    IOSPYLayoutRoothide,
};

#ifdef __cplusplus
extern "C" {
#endif

IOSPYLayout IOSPYDetectLayout(void);
NSString *IOSPYLayoutName(IOSPYLayout layout);

// "ElleKit", "Substitute", "Substrate", or "unknown".
NSString *IOSPYInjectionFramework(void);

// e.g. "iPhone10,3".
NSString *IOSPYDeviceModel(void);

// Marketing OS version, e.g. "16.7.10".
NSString *IOSPYSystemVersion(void);

#ifdef __cplusplus
}
#endif
