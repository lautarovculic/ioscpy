//! Command-line flags. The normal case is just `ioscpy` with no flags, the rest
//! is for support and debugging.

use clap::{Parser, ValueEnum};

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum StreamProfile {
    /// Preserve the original 45 FPS / 1600 px behavior.
    Legacy,
    /// Favor detail at 60 FPS with a higher bitrate.
    Quality,
    /// General-purpose 60 FPS mode.
    Balanced,
    /// Short queues and a smaller frame for lower latency.
    Latency,
    /// Experimental 90 FPS mode; --fps 120 keeps a 2160 long edge unless
    /// explicitly overridden.
    HighRefresh,
}

#[derive(Parser, Debug, Clone)]
#[command(
    name = "ioscpy",
    version,
    about = "Mirror and control a jailbroken iPhone from macOS over USB",
    long_about = "ioscpy mirrors and controls a jailbroken iPhone from macOS over USB.\n\
                  Run with no arguments to auto-connect the single attached device.\n\
                  Video settings are available from the macOS menu and persist.\n\
                  All core features (screen, mouse, keyboard, clipboard, shortcuts,\n\
                  orientation, reconnect) are enabled by default."
)]
pub struct Cli {
    /// Select a specific device by UDID (required when multiple are attached).
    #[arg(long, value_name = "UDID")]
    pub device: Option<String>,

    /// List attached compatible devices and exit.
    #[arg(long)]
    pub list: bool,

    /// Print full diagnostics (host/device versions, transport, backends).
    #[arg(long)]
    pub debug: bool,

    /// Trace mouse-to-touch delivery on both the Mac and device. This is meant
    /// for diagnosing jailbreak/input backend compatibility and is intentionally
    /// separate from the much noisier general --debug output.
    #[arg(long)]
    pub input_debug: bool,

    /// Force MJPEG instead of H.264, in case H.264 acts up on some device.
    #[arg(long)]
    pub mjpeg: bool,

    /// Select a stream tuning preset. With no preset or overrides, ioscpy keeps
    /// the original 45 FPS / 1600 px behavior for compatibility.
    #[arg(long, value_enum, value_name = "PROFILE")]
    pub profile: Option<StreamProfile>,

    /// Override the requested capture frame rate (1-240).
    #[arg(long, value_name = "FPS", value_parser = clap::value_parser!(u16).range(1..=240))]
    pub fps: Option<u16>,

    /// Override the longest captured dimension in pixels (320-4096).
    #[arg(long, value_name = "PIXELS", value_parser = clap::value_parser!(u16).range(320..=4096))]
    pub max_dimension: Option<u16>,

    /// Override the H.264 target bitrate in megabits per second (1-100).
    #[arg(long, value_name = "MBPS", value_parser = clap::value_parser!(u32).range(1..=100))]
    pub bitrate_mbps: Option<u32>,

    /// Request an H.264 keyframe interval in seconds (1-30).
    #[arg(long, value_name = "SECONDS", value_parser = clap::value_parser!(u16).range(1..=30))]
    pub keyframe_seconds: Option<u16>,

    /// Stay on native Wayland even when the compositor draws no window
    /// decorations for us (GNOME/mutter). By default ioscpy falls back to
    /// X11/XWayland there so the window gets a titlebar.
    #[cfg(all(unix, not(target_os = "macos")))]
    #[arg(long)]
    pub wayland: bool,

    /// Hide the on-screen iOS keyboard while connected, so the mirror shows the
    /// full screen (you type from the Mac; the device acts as if a hardware
    /// keyboard is attached). The keyboard returns when ioscpy exits. iOS 16+.
    #[arg(long)]
    pub no_keyboard: bool,

    // hidden options for debugging, not part of normal use
    /// Connect directly to host:port. Non-loopback/LAN daemons require
    /// --pair-token-file and must be explicitly enabled on the device.
    #[arg(long, alias = "lan", value_name = "HOST:PORT")]
    pub addr: Option<String>,

    /// Read the LAN pairing token from a local file. The token is not accepted as
    /// a command-line value so it does not leak into shell history/process lists.
    #[arg(long, value_name = "PATH", requires = "addr")]
    pub pair_token_file: Option<String>,

    /// Override the daemon port (default 27183).
    #[arg(long, value_name = "PORT", hide = true)]
    pub port: Option<u16>,

    /// Connect, handshake, print the capability map, then exit (no UI).
    #[arg(long, hide = true)]
    pub handshake_only: bool,

    /// Save the first streamed frame (JPEG) to this path and exit. For testing
    /// the capture/stream path without opening a window.
    #[arg(long, value_name = "PATH", hide = true)]
    pub snapshot: Option<String>,

    /// Stream for N seconds with no window and report fps / bandwidth / decode
    /// time. For measuring stream performance.
    #[arg(long, value_name = "SECONDS", hide = true)]
    pub bench: Option<u64>,

    /// Write the benchmark report as JSON. Use `-` to print JSON to stdout.
    #[arg(long, value_name = "PATH", requires = "bench", hide = true)]
    pub bench_json: Option<String>,

    /// Send one SYSTEM_ACTION code (1=Home 2=Lock 3=Wake 4=AppSwitcher) and report
    /// whether the stream survives it. For testing system actions headlessly.
    #[arg(long, value_name = "CODE", hide = true)]
    pub action: Option<u16>,

    /// Run the full streaming session (no window) for N seconds, surfacing any
    /// reconnects. For reproducing session-loop instability headlessly.
    #[arg(long, value_name = "SECONDS", hide = true)]
    pub soak: Option<u64>,
}

impl Cli {
    pub fn parse_args() -> Self {
        Cli::parse()
    }
}
