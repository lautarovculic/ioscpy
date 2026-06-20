#import "Paths.h"

#import <stdlib.h>
#import <mach-o/dyld.h>
#import <limits.h>

// Work out the jailbreak prefix from where this binary lives. jbcompat is only
// linked into ioscpyd / ioscpyctl, both installed at <prefix>/usr/bin/<tool>, so
// the prefix is just that path with the trailing /usr/bin/<tool> stripped. Works
// on rootless (/var/jb), rootful (""), and roothide (random prefix) with no
// special cases, since dpkg already put us under the right prefix.
static NSString *prefixFromOwnPath(void) {
    char buf[PATH_MAX];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) {
        return nil;
    }
    NSString *exe = [NSString stringWithUTF8String:buf];
    NSRange r = [exe rangeOfString:@"/usr/bin/" options:NSBackwardsSearch];
    if (r.location == NSNotFound) {
        return nil; // launched from somewhere odd, let the caller fall back
    }
    NSString *prefix = [exe substringToIndex:r.location];
    // A bare "/usr/bin/..." means the real root (rootful), so empty prefix.
    return [prefix isEqualToString:@"/"] ? @"" : prefix;
}

NSString *IOSPYJBPrefix(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];

        // Prefer our own install location, but only trust it if the daemon is
        // actually there, so a weird exec path can't poison the cache.
        NSString *own = prefixFromOwnPath();
        if (own && [fm fileExistsAtPath:[own stringByAppendingString:@"/usr/bin/ioscpyd"]]) {
            cached = own;
            return;
        }

        // Fallbacks, in case we were launched from an odd path.

        // Some bootstraps set the root in the environment.
        const char *env = getenv("JBROOT");
        if (env && env[0]) {
            NSString *p = [NSString stringWithUTF8String:env];
            if ([fm fileExistsAtPath:p]) {
                cached = ([p isEqualToString:@"/"]) ? @"" : p;
                return;
            }
        }

        // Standard rootless location.
        if ([fm fileExistsAtPath:@"/var/jb"]) {
            cached = @"/var/jb";
            return;
        }

        // Rootful: everything lives at the real root.
        cached = @"";
    });
    return cached;
}

NSString *IOSPYPath(NSString *relative) {
    if (relative.length == 0) {
        return IOSPYJBPrefix();
    }
    if (![relative hasPrefix:@"/"]) {
        relative = [@"/" stringByAppendingString:relative];
    }
    return [IOSPYJBPrefix() stringByAppendingString:relative];
}
