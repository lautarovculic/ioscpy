//! Host side of the wire protocol. This must stay in sync with the daemon's
//! version. Any change here bumps [`PROTOCOL_VERSION`].

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

pub const MAGIC: u32 = 0x4943_5059; // "ICPY"
pub const PROTOCOL_VERSION: u16 = 4;
pub const HEADER_SIZE: usize = 32;
pub const DEFAULT_PORT: u16 = 27183;
pub const MAX_PAYLOAD: u32 = 16 * 1024 * 1024;

// Logical channels (`stream_id`).
pub const CHANNEL_CONTROL: u64 = 0;
#[allow(dead_code)]
pub const CHANNEL_VIDEO: u64 = 1;

// Flag bits in the 16-byte VIDEO_FRAME sub-header (not the frame header) that
// tell the host how to read the encoded bytes. A plain JPEG frame clears them all.
/// Payload is H.264 in AVCC form rather than JPEG.
#[allow(dead_code)]
pub const VIDEO_FLAG_H264: u32 = 0x1;
/// H.264 keyframe (IDR), decodable on its own.
#[allow(dead_code)]
pub const VIDEO_FLAG_KEYFRAME: u32 = 0x2;
/// SPS/PPS parameter sets are prepended to this frame's data.
#[allow(dead_code)]
pub const VIDEO_FLAG_CONFIG: u32 = 0x4;

// Codec selector, the 1-byte START_STREAM payload. An empty payload also means
// MJPEG so an older daemon still streams a picture.
pub const VIDEO_CODEC_MJPEG: u8 = 0;
pub const VIDEO_CODEC_H264: u8 = 1;

// Capture orientation packed into VIDEO_FRAME flags bits 3-4 (value =
// orientation - 1). The frame is always the device's portrait framebuffer.
pub const VIDEO_ORIENT_SHIFT: u32 = 3;
pub const VIDEO_ORIENT_MASK: u32 = 0x18;

/// Orientation carried in a VIDEO_FRAME's flags: 1=portrait, 2=upsideDown,
/// 3=landscapeLeft, 4=landscapeRight.
pub fn video_orientation(flags: u32) -> u8 {
    (((flags & VIDEO_ORIENT_MASK) >> VIDEO_ORIENT_SHIFT) as u8) + 1
}

/// Message type numbers. Stable wire values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum MessageType {
    Hello = 1,
    HelloAck = 2,
    CapabilitiesRequest = 3,
    CapabilitiesResponse = 4,
    Authenticate = 5,
    StartStream = 10,
    StopStream = 11,
    VideoFrame = 12,
    RequestKeyframe = 13,
    InputTouch = 20,
    InputKey = 21,
    InputText = 22,
    ClipboardGet = 30,
    ClipboardSet = 31,
    ClipboardChanged = 32,
    OrientationChanged = 40,
    ScreenInfo = 41,
    SystemAction = 50,
    KeyboardMode = 51,
    Ping = 60,
    Pong = 61,
    Error = 70,
    Log = 71,
}

impl MessageType {
    pub fn from_u16(v: u16) -> Option<Self> {
        use MessageType::*;
        Some(match v {
            1 => Hello,
            2 => HelloAck,
            3 => CapabilitiesRequest,
            4 => CapabilitiesResponse,
            5 => Authenticate,
            10 => StartStream,
            11 => StopStream,
            12 => VideoFrame,
            13 => RequestKeyframe,
            20 => InputTouch,
            21 => InputKey,
            22 => InputText,
            30 => ClipboardGet,
            31 => ClipboardSet,
            32 => ClipboardChanged,
            40 => OrientationChanged,
            41 => ScreenInfo,
            50 => SystemAction,
            51 => KeyboardMode,
            60 => Ping,
            61 => Pong,
            70 => Error,
            71 => Log,
            _ => return None,
        })
    }
}

/// Fixed 32-byte frame header. Every field is on the wire even though routing
/// only uses some of them today.
#[derive(Debug, Clone, Copy)]
#[allow(dead_code)]
pub struct FrameHeader {
    pub version: u16,
    pub msg_type: u16,
    pub flags: u32,
    pub stream_id: u64,
    pub seq: u64,
    pub length: u32,
}

#[derive(Debug)]
pub struct Frame {
    pub header: FrameHeader,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn message_type(&self) -> Option<MessageType> {
        MessageType::from_u16(self.header.msg_type)
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ProtocolError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("bad magic: expected ICPY, got {0:#010x}")]
    BadMagic(u32),
    #[error("unsupported protocol version: {0}")]
    BadVersion(u16),
    #[error("frame payload too large: {0} bytes (max {MAX_PAYLOAD})")]
    PayloadTooLarge(u32),
    #[error("unexpected message type {got}, expected {expected}")]
    Unexpected { got: u16, expected: &'static str },
    #[error("json decode error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("the phone side reported a problem [{code}]: {message}")]
    Daemon { code: String, message: String },
    #[error(
        "the iPhone is connected but ioscpy on the phone didn't answer in time. \
         Make sure ioscpy is installed on the phone (from your Sileo or Zebra repo) \
         and respring it, then try again."
    )]
    Timeout,
}

/// Read exactly `buf.len()` bytes, turning a socket timeout into a friendly
/// `Timeout` instead of a generic IO error.
fn read_exact_timed<R: Read>(r: &mut R, buf: &mut [u8]) -> Result<(), ProtocolError> {
    r.read_exact(buf).map_err(|e| match e.kind() {
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut => ProtocolError::Timeout,
        _ => ProtocolError::Io(e),
    })
}

/// Write a single frame.
pub fn write_frame<W: Write>(
    w: &mut W,
    msg_type: MessageType,
    stream_id: u64,
    seq: u64,
    payload: &[u8],
) -> Result<(), ProtocolError> {
    let mut hdr = [0u8; HEADER_SIZE];
    hdr[0..4].copy_from_slice(&MAGIC.to_be_bytes());
    hdr[4..6].copy_from_slice(&PROTOCOL_VERSION.to_be_bytes());
    hdr[6..8].copy_from_slice(&(msg_type as u16).to_be_bytes());
    hdr[8..12].copy_from_slice(&0u32.to_be_bytes()); // flags
    hdr[12..20].copy_from_slice(&stream_id.to_be_bytes());
    hdr[20..28].copy_from_slice(&seq.to_be_bytes());
    hdr[28..32].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    w.write_all(&hdr)?;
    if !payload.is_empty() {
        w.write_all(payload)?;
    }
    w.flush()?;
    Ok(())
}

/// Read a single frame, validating magic/version/length.
pub fn read_frame<R: Read>(r: &mut R) -> Result<Frame, ProtocolError> {
    let mut hdr = [0u8; HEADER_SIZE];
    read_exact_timed(r, &mut hdr)?;
    let magic = u32::from_be_bytes(hdr[0..4].try_into().unwrap());
    if magic != MAGIC {
        return Err(ProtocolError::BadMagic(magic));
    }
    let version = u16::from_be_bytes(hdr[4..6].try_into().unwrap());
    if version != PROTOCOL_VERSION {
        return Err(ProtocolError::BadVersion(version));
    }
    let msg_type = u16::from_be_bytes(hdr[6..8].try_into().unwrap());
    let flags = u32::from_be_bytes(hdr[8..12].try_into().unwrap());
    let stream_id = u64::from_be_bytes(hdr[12..20].try_into().unwrap());
    let seq = u64::from_be_bytes(hdr[20..28].try_into().unwrap());
    let length = u32::from_be_bytes(hdr[28..32].try_into().unwrap());
    if length > MAX_PAYLOAD {
        return Err(ProtocolError::PayloadTooLarge(length));
    }
    let mut payload = vec![0u8; length as usize];
    read_exact_timed(r, &mut payload)?;
    Ok(Frame {
        header: FrameHeader {
            version,
            msg_type,
            flags,
            stream_id,
            seq,
            length,
        },
        payload,
    })
}

// ---------------------------------------------------------------------------
// Handshake and capability payloads. JSON, since they're low frequency.
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct Hello {
    pub role: &'static str,
    pub host_version: String,
    pub protocol_version: u16,
    pub nonce: String,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct HelloAck {
    pub daemon_version: String,
    pub protocol_version: u16,
    pub session_token: String,
    pub capabilities: Capabilities,
}

/// What the daemon says it can do, sent at handshake. The host picks backends
/// from this and assumes nothing that isn't advertised.
#[derive(Debug, Clone, Deserialize)]
pub struct Capabilities {
    pub ios_version: String,
    pub device_model: String,
    pub jailbreak_layout: String,
    #[serde(default)]
    pub jb_prefix: String,
    #[serde(default)]
    pub injection_framework: String,
    #[serde(default)]
    pub daemon_uid: i64,
    #[serde(default)]
    pub stream_backends: Vec<String>,
    #[serde(default)]
    pub input_backends: Vec<String>,
    #[serde(default)]
    pub clipboard: bool,
    #[serde(default)]
    pub keyboard: bool,
    #[serde(default)]
    pub orientation: bool,
}

/// Touch phase, the first byte of an INPUT_TOUCH payload.
#[derive(Debug, Clone, Copy)]
#[repr(u8)]
pub enum TouchPhase {
    Down = 0,
    Move = 1,
    Up = 2,
}

/// System actions (`SYSTEM_ACTION` payload, u16). Stable wire values. Not every
/// one has a shortcut yet.
#[derive(Debug, Clone, Copy)]
#[allow(dead_code)]
#[repr(u16)]
pub enum SystemAction {
    Home = 1,
    Lock = 2,
    Wake = 3,
    AppSwitcher = 4,
    RotateLeft = 5,
    RotateRight = 6,
    Screenshot = 7,
    Back = 8,
}

/// Encode an INPUT_TOUCH payload: `phase(u8) id(u8) x(f32 BE) y(f32 BE)`, with
/// x/y normalized to [0, 1] of the screen.
pub fn encode_touch(phase: TouchPhase, id: u8, x: f32, y: f32) -> Vec<u8> {
    let mut v = Vec::with_capacity(10);
    v.push(phase as u8);
    v.push(id);
    v.extend_from_slice(&x.to_be_bytes());
    v.extend_from_slice(&y.to_be_bytes());
    v
}

/// Encode a SYSTEM_ACTION payload: a single big-endian u16 action code.
pub fn encode_system_action(action: SystemAction) -> Vec<u8> {
    (action as u16).to_be_bytes().to_vec()
}

/// A non-text key event (`INPUT_KEY` payload, one byte). Editing keys and the
/// iOS editing shortcuts. The device maps each to the right HID usage or chord.
#[derive(Debug, Clone, Copy)]
#[allow(dead_code)]
#[repr(u8)]
pub enum KeyCode {
    Enter = 1,
    Backspace = 2,
    Tab = 3,
    Escape = 4,
    Left = 5,
    Right = 6,
    Up = 7,
    Down = 8,
    SelectAll = 10, // Cmd+A
    Copy = 11,      // Cmd+C
    Paste = 12,     // Cmd+V
    Cut = 13,       // Cmd+X
    Undo = 14,      // Cmd+Z
}

/// Encode an INPUT_KEY payload: a single key code byte.
pub fn encode_key(code: KeyCode) -> Vec<u8> {
    vec![code as u8]
}

/// Encode a KEYBOARD_MODE payload: one byte, non-zero to hide the on-screen
/// keyboard, so the device acts like a hardware keyboard is attached.
pub fn encode_keyboard_mode(suppress: bool) -> Vec<u8> {
    vec![suppress as u8]
}

/// Encode an INPUT_TEXT payload: the typed text as UTF-8. The Mac already
/// applied its keyboard layout, so this is just characters. The device types
/// them, ASCII via HID and the rest via paste.
pub fn encode_text(text: &str) -> Vec<u8> {
    text.as_bytes().to_vec()
}

/// Parse a VIDEO_FRAME payload: a 16-byte big-endian header (width, height,
/// flags, data length) then the encoded bytes, JPEG or H.264 AVCC depending on
/// `flags`. Returns `(width, height, flags, data)`. `flags` is 0 for plain JPEG.
pub fn parse_video_payload(payload: &[u8]) -> Option<(u32, u32, u32, &[u8])> {
    if payload.len() < 16 {
        return None;
    }
    let width = u32::from_be_bytes(payload[0..4].try_into().unwrap());
    let height = u32::from_be_bytes(payload[4..8].try_into().unwrap());
    let flags = u32::from_be_bytes(payload[8..12].try_into().unwrap());
    let len = u32::from_be_bytes(payload[12..16].try_into().unwrap()) as usize;
    let end = 16usize.checked_add(len)?;
    if payload.len() < end {
        return None;
    }
    Some((width, height, flags, &payload[16..end]))
}

/// A log line streamed from the daemon.
#[derive(Debug, Clone, Deserialize)]
pub struct LogMessage {
    #[serde(default = "default_level")]
    pub level: String,
    pub message: String,
}

fn default_level() -> String {
    "info".to_string()
}

/// A recoverable error from the daemon. The extra fields get shown to the user
/// as the error handling fills in.
#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)]
pub struct DaemonError {
    pub code: String,
    pub component: String,
    pub fatal: bool,
    pub message: String,
    #[serde(default)]
    pub suggestion: String,
}

/// Short random hex string from the OS RNG. No crypto crate needed, the
/// handshake nonce just has to be unique.
pub fn random_hex(bytes: usize) -> String {
    use std::fs::File;
    let mut buf = vec![0u8; bytes];
    if let Ok(mut f) = File::open("/dev/urandom") {
        let _ = f.read_exact(&mut buf);
    }
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

/// Run the handshake: send HELLO, expect HELLO_ACK, turn a daemon ERROR into a
/// typed error.
pub fn handshake<S: Read + Write>(
    stream: &mut S,
    host_version: &str,
) -> Result<HelloAck, ProtocolError> {
    let hello = Hello {
        role: "host",
        host_version: host_version.to_string(),
        protocol_version: PROTOCOL_VERSION,
        nonce: random_hex(16),
    };
    let body = serde_json::to_vec(&hello)?;
    write_frame(stream, MessageType::Hello, CHANNEL_CONTROL, 0, &body)?;

    let frame = read_frame(stream)?;
    let ack: HelloAck = match frame.message_type() {
        Some(MessageType::HelloAck) => serde_json::from_slice(&frame.payload)?,
        Some(MessageType::Error) => {
            let e: DaemonError = serde_json::from_slice(&frame.payload)?;
            // append the daemon's hint so the user sees it
            let message = if e.suggestion.trim().is_empty() {
                e.message
            } else {
                format!("{} ({})", e.message, e.suggestion)
            };
            return Err(ProtocolError::Daemon {
                code: e.code,
                message,
            });
        }
        _ => {
            return Err(ProtocolError::Unexpected {
                got: frame.header.msg_type,
                expected: "HELLO_ACK",
            })
        }
    };

    // echo the session token back. The daemon ignores privileged messages
    // (input, clipboard, system actions) until it sees the matching token, so
    // this has to happen on every handshake.
    write_frame(
        stream,
        MessageType::Authenticate,
        CHANNEL_CONTROL,
        0,
        ack.session_token.as_bytes(),
    )?;
    Ok(ack)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn frame_roundtrip() {
        let mut buf = Vec::new();
        write_frame(&mut buf, MessageType::Hello, CHANNEL_CONTROL, 7, b"hi").unwrap();
        assert_eq!(buf.len(), HEADER_SIZE + 2);
        let mut cur = Cursor::new(buf);
        let f = read_frame(&mut cur).unwrap();
        assert_eq!(f.message_type(), Some(MessageType::Hello));
        assert_eq!(f.header.stream_id, CHANNEL_CONTROL);
        assert_eq!(f.header.seq, 7);
        assert_eq!(f.payload, b"hi");
    }

    #[test]
    fn rejects_bad_magic() {
        let mut bad = vec![0u8; HEADER_SIZE];
        bad[28..32].copy_from_slice(&0u32.to_be_bytes());
        let mut cur = Cursor::new(bad);
        assert!(matches!(
            read_frame(&mut cur),
            Err(ProtocolError::BadMagic(_))
        ));
    }

    #[test]
    fn message_type_roundtrip() {
        for v in [1u16, 2, 5, 12, 13, 50, 60, 61, 70, 71] {
            let mt = MessageType::from_u16(v).unwrap();
            assert_eq!(mt as u16, v);
        }
        assert!(MessageType::from_u16(9999).is_none());
    }
}
