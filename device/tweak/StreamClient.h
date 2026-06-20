// Runs inside SpringBoard. Connects to the daemon's frame channel, waits for a
// start command, then captures the screen on a timer and pushes JPEG frames
// across. Capture only runs while the daemon asks for it.

#import <Foundation/Foundation.h>

@interface IOSPYStreamClient : NSObject

+ (instancetype)shared;

// Begin the connect/reconnect loop to the daemon on a background thread.
- (void)start;

@end
