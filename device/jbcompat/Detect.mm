#import "Detect.h"
#import "Paths.h"

#import <sys/sysctl.h>

IOSPYLayout IOSPYDetectLayout(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *prefix = IOSPYJBPrefix();

    if ([prefix isEqualToString:@"/var/jb"]) {
        return IOSPYLayoutRootless;
    }
    if (prefix.length > 0) {
        // Non-empty, non-standard prefix means a dynamic root.
        return IOSPYLayoutRoothide;
    }
    // Empty prefix means the real root is writable. Check for either Substrate or
    // ElleKit since recent palera1n ships ElleKit only.
    if ([fm isWritableFileAtPath:@"/var"] &&
        ([fm fileExistsAtPath:@"/Library/MobileSubstrate"] ||
         [fm fileExistsAtPath:@"/usr/lib/libellekit.dylib"])) {
        return IOSPYLayoutRootful;
    }
    return IOSPYLayoutUnknown;
}

NSString *IOSPYLayoutName(IOSPYLayout layout) {
    switch (layout) {
        case IOSPYLayoutRootless: return @"rootless";
        case IOSPYLayoutRootful:  return @"rootful";
        case IOSPYLayoutRoothide: return @"roothide";
        default:                  return @"unknown";
    }
}

NSString *IOSPYInjectionFramework(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // Check ElleKit first. It ships a Substrate-compatible shim, so checking
    // Substrate first would hide it.
    if ([fm fileExistsAtPath:IOSPYPath(@"/usr/lib/libellekit.dylib")]) {
        return @"ElleKit";
    }
    if ([fm fileExistsAtPath:IOSPYPath(@"/usr/lib/libsubstitute.dylib")] ||
        [fm fileExistsAtPath:IOSPYPath(@"/usr/lib/substitute-loader.dylib")]) {
        return @"Substitute";
    }
    if ([fm fileExistsAtPath:IOSPYPath(@"/usr/lib/libsubstrate.dylib")] ||
        [fm fileExistsAtPath:IOSPYPath(@"/Library/MobileSubstrate/MobileSubstrate.dylib")]) {
        return @"Substrate";
    }
    return @"unknown";
}

NSString *IOSPYDeviceModel(void) {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) {
        return @"unknown";
    }
    char *model = (char *)malloc(size);
    if (!model) {
        return @"unknown";
    }
    NSString *result = @"unknown";
    if (sysctlbyname("hw.machine", model, &size, NULL, 0) == 0) {
        result = [NSString stringWithUTF8String:model];
    }
    free(model);
    return result;
}

NSString *IOSPYSystemVersion(void) {
    NSDictionary *info =
        [NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
    NSString *v = info[@"ProductVersion"];
    if (v.length) {
        return v;
    }
    NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
    return [NSString stringWithFormat:@"%ld.%ld.%ld",
                                      (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion];
}
