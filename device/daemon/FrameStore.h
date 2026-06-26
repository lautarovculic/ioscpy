// Holds the latest video frame from the tweak, so a connected host can be served
// the newest image without the capture side blocking on it.

#import <Foundation/Foundation.h>

@interface IOSPYFrameStore : NSObject

+ (instancetype)shared;

// Replace the latest frame (a ready-to-forward VIDEO_FRAME payload: the small
// dimensions header plus JPEG bytes). Bumps the sequence number.
- (void)setPayload:(NSData *)payload;

// If a frame newer than *seq is available, return it and advance *seq to it;
// otherwise return nil and leave *seq untouched.
- (NSData *)payloadNewerThan:(uint64_t *)seq;

// Snapshot the current sequence so a new pump waits for frames from this stream
// instead of immediately replaying the previous stream's last MJPEG frame.
- (uint64_t)currentSequence;

@end
