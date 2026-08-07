// Loopback channel the SpringBoard tweak connects to. The tweak pushes captured
// frames in, the daemon pushes start/stop commands out. Capture stays off unless
// a host is actually watching.

#import <Foundation/Foundation.h>

@interface IOSPYFrameIngest : NSObject

+ (instancetype)shared;

// Bind the loopback frame port and start accepting the tweak connection.
- (BOOL)startOnPort:(uint16_t)port;

// Whether a tweak is currently connected and able to stream.
- (BOOL)tweakConnected;

// Tell the tweak to begin capturing with the versioned START_STREAM payload.
// Byte zero remains the codec selector for compatibility.
- (void)tellTweakStartPayload:(NSData *)payload;
- (void)tellTweakStop;

// Choose how incoming video frames reach the host. MJPEG (NO) keeps only the
// latest frame and drops under backpressure. H.264 (YES) forwards every frame in
// order so the inter-frame stream stays intact.
- (void)setVideoReliable:(BOOL)reliable;

// Forward a control frame (e.g. input/system action) to the tweak.
- (void)forwardToTweak:(uint16_t)type payload:(NSData *)payload;

// Register or clear the connected host's control socket so the tweak->host
// direction (e.g. clipboard changes) can be relayed. The write lock is the
// control server's per-connection lock, shared so writes don't interleave with
// the video pump.
- (void)setHostFd:(int)fd writeLock:(NSLock *)lock;

// LAN media path. Control/input remain on the authenticated TCP socket while
// encoded video is sent as small UDP datagrams to avoid TCP head-of-line stalls.
// Passing port 0 clears the destination and restores the normal TCP video path.
- (void)setLANVideoPeerAddress:(uint32_t)addressNetworkOrder
                           port:(uint16_t)portHostOrder
                          token:(uint64_t)token;

@end
