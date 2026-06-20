//! Command-line flags. The normal case is just `ioscpy` with no flags, the rest
//! is for support and debugging.

use clap::Parser;

#[derive(Parser, Debug, Clone)]
#[command(
    name = "ioscpy",
    version,
    about = "Mirror and control a jailbroken iPhone from macOS over USB",
    long_about = "ioscpy mirrors and controls a jailbroken iPhone from macOS over USB.\n\
                  Run with no arguments to auto-connect the single attached device.\n\
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

    /// Force MJPEG instead of H.264, in case H.264 acts up on some device.
    #[arg(long)]
    pub mjpeg: bool,

    /// Hide the on-screen iOS keyboard while connected, so the mirror shows the
    /// full screen (you type from the Mac; the device acts as if a hardware
    /// keyboard is attached). The keyboard returns when ioscpy exits. iOS 16+.
    #[arg(long)]
    pub no_keyboard: bool,

    // hidden options for debugging, not part of normal use
    /// Connect directly to host:port, bypassing usbmux/iproxy (debugging only).
    #[arg(long, value_name = "ADDR", hide = true)]
    pub addr: Option<String>,

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
