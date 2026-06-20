//! USB transport. The user never runs `iproxy` by hand. We spawn it for the
//! session and kill it on drop.
//!
//! A native usbmux client could replace the `iproxy` child later, the API
//! (`start` / `connect` / `local_port`) wouldn't change.

use std::net::{TcpListener, TcpStream};
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};

/// A live USB port forward from a local TCP port to a device port over usbmux.
pub struct UsbForward {
    child: Child,
    pub local_port: u16,
    pub device_port: u16,
}

impl UsbForward {
    /// Spawn the forwarder for `udid` and wait until the local port accepts.
    ///
    /// We pick a free port and hand it to iproxy, which leaves a small window
    /// where something else could grab it. Retry a few times with a fresh port
    /// so a lost race heals itself instead of failing the session.
    pub fn start(udid: &str, device_port: u16) -> Result<Self> {
        let mut last_err = None;
        for attempt in 1..=3 {
            match Self::start_once(udid, device_port) {
                Ok(forward) => return Ok(forward),
                Err(e) => {
                    last_err = Some(e);
                    if attempt < 3 {
                        sleep(Duration::from_millis(120));
                    }
                }
            }
        }
        Err(last_err.expect("retry loop ran at least once"))
    }

    fn start_once(udid: &str, device_port: u16) -> Result<Self> {
        let local_port = free_local_port()?;
        let pair = format!("{local_port}:{device_port}");

        let mut child = Command::new("iproxy")
            .arg(&pair)
            .arg("-u")
            .arg(udid)
            .arg("-l") // USB device only, never network
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .context("couldn't start the USB link. The USB tools are missing. Install them with:  brew install libimobiledevice")?;

        let deadline = Instant::now() + Duration::from_secs(6);
        loop {
            if let Ok(Some(status)) = child.try_wait() {
                bail!("the USB link to the iPhone closed right away ({status}). Unplug the phone, plug it back in, and try again.");
            }
            if TcpStream::connect(("127.0.0.1", local_port)).is_ok() {
                break;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                bail!("couldn't reach the iPhone over USB. Check the cable, unlock the phone, and tap Trust if it asks.");
            }
            sleep(Duration::from_millis(80));
        }

        Ok(Self {
            child,
            local_port,
            device_port,
        })
    }

    /// Open a new connection to the device through the forward.
    pub fn connect(&self) -> Result<TcpStream> {
        let s = TcpStream::connect(("127.0.0.1", self.local_port))
            .with_context(|| format!("connect 127.0.0.1:{}", self.local_port))?;
        s.set_nodelay(true).ok();
        Ok(s)
    }
}

impl Drop for UsbForward {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Get a free loopback port by binding to port 0 and reading it back.
fn free_local_port() -> Result<u16> {
    let listener = TcpListener::bind(("127.0.0.1", 0)).context("reserve a local port")?;
    Ok(listener.local_addr()?.port())
}
