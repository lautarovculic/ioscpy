// Filesystem prefix resolution. Every installed path is derived from the
// runtime-resolved prefix so the same code works on rootless, rootful, and
// dynamically-prefixed layouts.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// The active jailbreak prefix: "/var/jb" on rootless, "" on rootful, or a
// dynamically detected root elsewhere.
NSString *IOSPYJBPrefix(void);

// Join a prefix-relative path (e.g. "/usr/bin/ioscpyd") onto the active prefix.
NSString *IOSPYPath(NSString *relative);

#ifdef __cplusplus
}
#endif
