#import <Foundation/Foundation.h>

typedef void (^IOSPYAudioPacketHandler)(NSData *packet);

// Experimental system-playback capture. ReplayKit is resolved in SpringBoard,
// so failure remains isolated from video/input and simply produces no packets.
@interface IOSPYAudioCapture : NSObject
- (void)startWithHandler:(IOSPYAudioPacketHandler)handler;
- (void)stop;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
@end
