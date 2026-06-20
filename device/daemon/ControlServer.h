// Loopback control server. Accepts the host connection over the USB-forwarded
// port, answers the handshake with the capability map, and keeps the control
// channel alive (ping/pong, capability refresh).

#import <Foundation/Foundation.h>

extern NSString *const IOSPYDaemonVersion;

@interface IOSPYControlServer : NSObject

- (instancetype)initWithPort:(uint16_t)port;

// Bind and listen. Returns NO with *error set on failure.
- (BOOL)startAndReturnError:(NSError **)error;

// Accept connections forever. Blocks the calling thread.
- (void)runLoop;

@end
