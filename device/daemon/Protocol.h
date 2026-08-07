// Wire framing for the control/video link. Must stay byte-for-byte compatible
// with the host side.

#import <Foundation/Foundation.h>

#define IOSPY_MAGIC            0x49435059u   // 'ICPY'
#define IOSPY_PROTOCOL_VERSION 5
#define IOSPY_HEADER_SIZE      32
#define IOSPY_DEFAULT_PORT     27183
#define IOSPY_FRAME_PORT       27184   // loopback channel between tweak and daemon
#define IOSPY_MAX_PAYLOAD      (16u * 1024u * 1024u)

#define IOSPY_CHANNEL_CONTROL  0ull
#define IOSPY_CHANNEL_VIDEO    1ull
#define IOSPY_CHANNEL_AUDIO    2ull

// Flag bits in the 16-byte VIDEO_FRAME sub-header. JPEG frames leave these clear;
// the H.264 path sets them so the host knows what the bytes are.
#define IOSPY_VIDEO_FLAG_H264     0x1u   // payload is H.264 (AVCC) not JPEG
#define IOSPY_VIDEO_FLAG_KEYFRAME 0x2u   // H.264 keyframe (IDR / sync sample)
#define IOSPY_VIDEO_FLAG_CONFIG   0x4u   // SPS/PPS parameter sets prepended
#define IOSPY_VIDEO_FLAG_HEVC     0x20u  // payload is HEVC (AVCC/HVCC NAL framing)

// Capture orientation in flags bits 3-4 (value = orientation - 1: 0=portrait,
// 1=upsideDown, 2=landscapeLeft, 3=landscapeRight). The frame is always the
// portrait framebuffer; the host uses this to rotate it upright.
#define IOSPY_VIDEO_ORIENT_SHIFT  3
#define IOSPY_VIDEO_ORIENT_MASK   0x18u

// START_STREAM codec selector (1-byte payload; empty payload also means MJPEG).
#define IOSPY_VIDEO_CODEC_MJPEG   0
#define IOSPY_VIDEO_CODEC_H264    1
#define IOSPY_VIDEO_CODEC_HEVC    2

// Extended START_STREAM payload. Byte zero remains the codec selector so an old
// daemon can safely ignore the remaining tuning fields.
#define IOSPY_STREAM_CONFIG_VERSION 2
#define IOSPY_STREAM_CONFIG_SIZE    16

typedef NS_ENUM(uint8_t, IOSPYLatencyMode) {
    IOSPYLatencyQuality = 0,
    IOSPYLatencyBalanced = 1,
    IOSPYLatencyLow = 2,
    IOSPYLatencyHighRefresh = 3,
};

typedef struct {
    uint8_t codec;
    uint16_t target_fps;
    uint16_t max_dimension;
    uint8_t latency_mode;
    uint32_t bitrate_bps;
    uint16_t keyframe_interval_frames;
} IOSPYStreamConfig;

typedef NS_ENUM(uint16_t, IOSPYMessageType) {
    IOSPYMsgHello                = 1,
    IOSPYMsgHelloAck             = 2,
    IOSPYMsgCapabilitiesRequest  = 3,
    IOSPYMsgCapabilitiesResponse = 4,
    IOSPYMsgAuthenticate         = 5,    // host echoes the session token to unlock input
    IOSPYMsgPairResult           = 6,
    IOSPYMsgStartStream          = 10,
    IOSPYMsgStopStream           = 11,
    IOSPYMsgVideoFrame           = 12,
    IOSPYMsgRequestKeyframe      = 13,
    IOSPYMsgInputTouch           = 20,
    IOSPYMsgInputKey             = 21,
    IOSPYMsgInputText            = 22,
    IOSPYMsgInputScroll          = 23,
    IOSPYMsgClipboardGet         = 30,
    IOSPYMsgClipboardSet         = 31,
    IOSPYMsgClipboardChanged     = 32,
    IOSPYMsgOrientationChanged   = 40,
    IOSPYMsgScreenInfo           = 41,
    IOSPYMsgSystemAction         = 50,
    IOSPYMsgKeyboardMode         = 51,   // [suppress:u8] hide/show the software keyboard
    IOSPYMsgDisplayMode          = 52,   // [black:u8] true OLED-off remote mode
    IOSPYMsgAudioMode            = 53,   // [enabled:u8] system playback audio capture
    IOSPYMsgUnlock               = 54,   // UTF-8 passcode, handled only on lock screen
    IOSPYMsgPing                 = 60,
    IOSPYMsgPong                 = 61,
    IOSPYMsgError                = 70,
    IOSPYMsgLog                  = 71,
    IOSPYMsgStats                = 72,
    IOSPYMsgAudioFrame           = 73,
    // LAN-only media acceleration. The authenticated host sends
    // [udp_port:u16][reserved:u16][session_token:u64], all big-endian. Video
    // then leaves the control TCP stream and is delivered as low-latency UDP
    // datagrams. USB continues to use the existing reliable stream.
    IOSPYMsgMediaBind            = 74,
};

typedef struct {
    uint16_t version;
    uint16_t type;
    uint32_t flags;
    uint64_t stream_id;
    uint64_t seq;
    uint32_t length;
} IOSPYFrameHeader;

#ifdef __cplusplus
extern "C" {
#endif

// Read one full frame from a socket. Returns NO on EOF/error or a bad header.
// On success *payload is the (possibly empty) payload.
BOOL IOSPYReadFrame(int fd, IOSPYFrameHeader *header, NSData **payload);

// Write one full frame. Returns NO if the socket write fails.
BOOL IOSPYWriteFrame(int fd, IOSPYMessageType type, uint64_t streamId, uint64_t seq, NSData *payload);

// Decode a START_STREAM payload, applying safe defaults for the original
// empty/one-byte form and clamping untrusted host values.
IOSPYStreamConfig IOSPYParseStreamConfig(NSData *payload);

// Try to write one frame without blocking. Returns 1 if fully sent, 0 if the
// send buffer was full so the frame is skipped (nothing left half-written), or
// -1 on a real error. Used for video so a slow peer drops frames instead of
// piling up a stale backlog.
int IOSPYTryWriteFrame(int fd, IOSPYMessageType type, uint64_t streamId, uint64_t seq, NSData *payload);

#ifdef __cplusplus
}
#endif
