//! Host-side stream codec selection.
//!
//! The daemon advertises what it can stream, but some device/OS combinations are
//! known to be fragile when H.264 is requested. Keep that policy here so the
//! session, bench, and tests all agree on the same default.

use crate::protocol::{self, Capabilities};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodecPreference {
    Auto,
    Mjpeg,
    H264,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodecChoiceReason {
    ExplicitMjpeg,
    ExplicitH264,
    FragileDeviceDefault,
    H264Advertised,
    H264Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CodecChoice {
    pub codec: u8,
    pub reason: CodecChoiceReason,
    pub profile: StreamProfile,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamProfile {
    pub max_dimension: u16,
    pub fps: u8,
    pub quality_percent: u8,
}

impl StreamProfile {
    const DEFAULT: Self = Self {
        max_dimension: 0,
        fps: 0,
        quality_percent: 0,
    };

    const FRAGILE_IPHONE_6S: Self = Self {
        max_dimension: 960,
        fps: 12,
        quality_percent: 55,
    };
}

pub fn choose_stream_codec(caps: &Capabilities, preference: CodecPreference) -> CodecChoice {
    match preference {
        CodecPreference::Mjpeg => CodecChoice {
            codec: protocol::VIDEO_CODEC_MJPEG,
            reason: CodecChoiceReason::ExplicitMjpeg,
            profile: StreamProfile::DEFAULT,
        },
        CodecPreference::H264 => CodecChoice {
            codec: protocol::VIDEO_CODEC_H264,
            reason: CodecChoiceReason::ExplicitH264,
            profile: StreamProfile::DEFAULT,
        },
        CodecPreference::Auto if !supports_h264(caps) => CodecChoice {
            codec: protocol::VIDEO_CODEC_MJPEG,
            reason: CodecChoiceReason::H264Unavailable,
            profile: StreamProfile::DEFAULT,
        },
        CodecPreference::Auto if has_fragile_h264_default(caps) => CodecChoice {
            codec: protocol::VIDEO_CODEC_MJPEG,
            reason: CodecChoiceReason::FragileDeviceDefault,
            profile: StreamProfile::FRAGILE_IPHONE_6S,
        },
        CodecPreference::Auto => CodecChoice {
            codec: protocol::VIDEO_CODEC_H264,
            reason: CodecChoiceReason::H264Advertised,
            profile: StreamProfile::DEFAULT,
        },
    }
}

pub fn start_stream_payload(choice: CodecChoice) -> Vec<u8> {
    if choice.profile == StreamProfile::DEFAULT {
        return vec![choice.codec];
    }
    let mut payload = Vec::with_capacity(5);
    payload.push(choice.codec);
    payload.extend_from_slice(&choice.profile.max_dimension.to_be_bytes());
    payload.push(choice.profile.fps);
    payload.push(choice.profile.quality_percent);
    payload
}

pub fn codec_name(codec: u8) -> &'static str {
    match codec {
        protocol::VIDEO_CODEC_H264 => "h264",
        _ => "mjpeg",
    }
}

fn supports_h264(caps: &Capabilities) -> bool {
    caps.stream_backends
        .iter()
        .any(|backend| backend.eq_ignore_ascii_case("h264"))
}

fn has_fragile_h264_default(caps: &Capabilities) -> bool {
    // iPhone 6s on iOS 15.x has been observed dropping USB/usbmux enumeration
    // when the host requests H.264. Keep the automatic path conservative while
    // still letting advanced users opt in with the hidden --h264 switch.
    matches!(
        (caps.device_model.trim(), ios_major(&caps.ios_version)),
        ("iPhone8,1", Some(15))
    )
}

fn ios_major(version: &str) -> Option<u16> {
    version
        .trim()
        .split('.')
        .next()
        .and_then(|major| major.parse::<u16>().ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn caps(device_model: &str, ios_version: &str, stream_backends: &[&str]) -> Capabilities {
        Capabilities {
            ios_version: ios_version.to_string(),
            device_model: device_model.to_string(),
            jailbreak_layout: String::new(),
            jb_prefix: String::new(),
            injection_framework: String::new(),
            daemon_uid: 0,
            stream_backends: stream_backends.iter().map(|s| s.to_string()).collect(),
            input_backends: Vec::new(),
            clipboard: false,
            keyboard: false,
            orientation: false,
        }
    }

    #[test]
    fn fragile_iphone81_ios15_defaults_to_mjpeg() {
        let choice = choose_stream_codec(
            &caps("iPhone8,1", "15.8.8", &["h264", "mjpeg"]),
            CodecPreference::Auto,
        );

        assert_eq!(choice.codec, protocol::VIDEO_CODEC_MJPEG);
        assert_eq!(choice.reason, CodecChoiceReason::FragileDeviceDefault);
        assert_eq!(
            choice.profile,
            StreamProfile {
                max_dimension: 960,
                fps: 12,
                quality_percent: 55,
            }
        );
        assert_eq!(start_stream_payload(choice), vec![0, 0x03, 0xc0, 12, 55]);
    }

    #[test]
    fn iphone81_outside_ios15_still_defaults_to_h264_when_advertised() {
        let choice = choose_stream_codec(
            &caps("iPhone8,1", "14.8.1", &["h264", "mjpeg"]),
            CodecPreference::Auto,
        );

        assert_eq!(choice.codec, protocol::VIDEO_CODEC_H264);
        assert_eq!(choice.reason, CodecChoiceReason::H264Advertised);
    }

    #[test]
    fn fragile_iphone81_ios15_can_explicitly_request_h264() {
        let choice = choose_stream_codec(
            &caps("iPhone8,1", "15.8.8", &["h264", "mjpeg"]),
            CodecPreference::H264,
        );

        assert_eq!(choice.codec, protocol::VIDEO_CODEC_H264);
        assert_eq!(choice.reason, CodecChoiceReason::ExplicitH264);
    }

    #[test]
    fn normal_h264_capable_device_defaults_to_h264() {
        let choice = choose_stream_codec(
            &caps("iPhone14,2", "17.5.1", &["h264", "mjpeg"]),
            CodecPreference::Auto,
        );

        assert_eq!(choice.codec, protocol::VIDEO_CODEC_H264);
        assert_eq!(choice.reason, CodecChoiceReason::H264Advertised);
    }

    #[test]
    fn explicit_mjpeg_wins_on_h264_capable_device() {
        let choice = choose_stream_codec(
            &caps("iPhone14,2", "17.5.1", &["h264", "mjpeg"]),
            CodecPreference::Mjpeg,
        );

        assert_eq!(choice.codec, protocol::VIDEO_CODEC_MJPEG);
        assert_eq!(choice.reason, CodecChoiceReason::ExplicitMjpeg);
    }

    #[test]
    fn h264_unavailable_defaults_to_mjpeg() {
        let choice = choose_stream_codec(
            &caps("iPhone14,2", "17.5.1", &["mjpeg"]),
            CodecPreference::Auto,
        );

        assert_eq!(choice.codec, protocol::VIDEO_CODEC_MJPEG);
        assert_eq!(choice.reason, CodecChoiceReason::H264Unavailable);
    }
}
