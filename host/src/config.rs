//! Persistent host configuration. Plain `ioscpy` loads the last video settings,
//! so frame rate and quality are controlled from the app instead of shell flags.

use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::protocol::{LatencyMode, StreamConfig, DEFAULT_PORT};

#[derive(Debug, Clone)]
pub struct HostConfig {
    /// Device port we forward to.
    pub port: u16,
}

impl Default for HostConfig {
    fn default() -> Self {
        Self { port: DEFAULT_PORT }
    }
}

/// User-facing video controls. Codec is deliberately excluded because the
/// handshake chooses H.264 or MJPEG for each connection.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct VideoSettings {
    pub target_fps: u16,
    pub max_dimension: u16,
    pub bitrate_mbps: u32,
    pub keyframe_seconds: u16,
    pub latency_mode: LatencyMode,
}

impl Default for VideoSettings {
    fn default() -> Self {
        // First-run default favors readability. Changing only FPS from the app
        // keeps this resolution instead of silently reducing it.
        Self::quality_60()
    }
}

impl VideoSettings {
    pub const fn quality_60() -> Self {
        Self {
            target_fps: 60,
            max_dimension: 2160,
            bitrate_mbps: 25,
            keyframe_seconds: 2,
            latency_mode: LatencyMode::Quality,
        }
    }

    pub const fn balanced_60() -> Self {
        Self {
            target_fps: 60,
            max_dimension: 1800,
            bitrate_mbps: 16,
            keyframe_seconds: 2,
            latency_mode: LatencyMode::Balanced,
        }
    }

    pub const fn ultra_120() -> Self {
        Self {
            target_fps: 120,
            max_dimension: 2160,
            bitrate_mbps: 40,
            keyframe_seconds: 1,
            // Quality disables automatic resolution reduction. The device still
            // drops stale frames instead of accumulating latency.
            latency_mode: LatencyMode::Quality,
        }
    }

    pub const fn native_120() -> Self {
        Self {
            target_fps: 120,
            // The device caps this to the panel's native dimensions.
            max_dimension: 4096,
            bitrate_mbps: 45,
            keyframe_seconds: 1,
            latency_mode: LatencyMode::Quality,
        }
    }

    pub const fn latency_60() -> Self {
        Self {
            target_fps: 60,
            max_dimension: 1280,
            bitrate_mbps: 8,
            keyframe_seconds: 2,
            latency_mode: LatencyMode::LowLatency,
        }
    }

    pub fn sanitized(mut self) -> Self {
        self.target_fps = self.target_fps.clamp(1, 240);
        self.max_dimension = self.max_dimension.clamp(320, 4096);
        self.bitrate_mbps = self.bitrate_mbps.clamp(1, 100);
        self.keyframe_seconds = self.keyframe_seconds.clamp(1, 30);
        self
    }

    pub fn stream_config(self, codec: u8) -> StreamConfig {
        let value = self.sanitized();
        StreamConfig {
            codec,
            target_fps: value.target_fps,
            max_dimension: value.max_dimension,
            latency_mode: value.latency_mode,
            bitrate_bps: value.bitrate_mbps.saturating_mul(1_000_000),
            keyframe_interval_frames: value.target_fps.saturating_mul(value.keyframe_seconds),
        }
    }

    pub fn summary(self) -> String {
        let resolution = if self.max_dimension >= 4096 {
            "Native".to_string()
        } else {
            format!("{}p", self.max_dimension)
        };
        format!(
            "{} FPS · {} · {} Mbps",
            self.target_fps, resolution, self.bitrate_mbps
        )
    }

    pub fn load() -> Self {
        let Some(path) = settings_path() else {
            return Self::default();
        };
        let Ok(bytes) = fs::read(path) else {
            return Self::default();
        };
        serde_json::from_slice::<Self>(&bytes)
            .map(Self::sanitized)
            .unwrap_or_default()
    }

    pub fn save(self) {
        let Some(path) = settings_path() else {
            return;
        };
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let Ok(bytes) = serde_json::to_vec_pretty(&self.sanitized()) else {
            return;
        };
        let tmp = path.with_extension("json.tmp");
        if fs::write(&tmp, bytes).is_ok() {
            let _ = fs::rename(tmp, path);
        }
    }
}

fn settings_path() -> Option<PathBuf> {
    let home = PathBuf::from(std::env::var_os("HOME")?);
    #[cfg(target_os = "macos")]
    {
        Some(
            home.join("Library")
                .join("Application Support")
                .join("ioscpy")
                .join("settings.json"),
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        Some(
            std::env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".config"))
                .join("ioscpy")
                .join("settings.json"),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn changing_fps_does_not_change_resolution() {
        let mut settings = VideoSettings::quality_60();
        settings.target_fps = 120;
        assert_eq!(settings.stream_config(1).max_dimension, 2160);
    }

    #[test]
    fn native_profile_caps_through_protocol_not_host_policy() {
        let cfg = VideoSettings::native_120().stream_config(1);
        assert_eq!(cfg.target_fps, 120);
        assert_eq!(cfg.max_dimension, 4096);
        assert_eq!(cfg.bitrate_bps, 45_000_000);
    }
}
