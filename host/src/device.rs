//! Finds attached devices by shelling out to `idevice_id` and `ideviceinfo`.
//! A native usbmux client could replace this later without touching the API.

use std::collections::BTreeSet;
use std::process::Command;

use anyhow::{anyhow, bail, Context, Result};

#[derive(Debug, Clone)]
pub struct Device {
    pub udid: String,
    pub name: String,
    pub product_type: String,
    pub ios_version: String,
}

impl Device {
    /// One-line summary used by `--list`.
    pub fn summary(&self) -> String {
        format!(
            "{}  {}  (iOS {})  \"{}\"",
            self.udid, self.product_type, self.ios_version, self.name
        )
    }
}

fn run(cmd: &str, args: &[&str]) -> Result<String> {
    let out = Command::new(cmd)
        .args(args)
        .output()
        .with_context(|| {
            format!("couldn't run `{cmd}`. The USB tools are missing. Install them with:  brew install libimobiledevice")
        })?;
    if !out.status.success() {
        bail!(
            "`{cmd} {}` failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn ideviceinfo(udid: &str, key: &str) -> String {
    run("ideviceinfo", &["-u", udid, "-k", key]).unwrap_or_else(|_| "unknown".to_string())
}

/// List attached devices, deduped across USB and network entries.
pub fn list_devices() -> Result<Vec<Device>> {
    let raw = run("idevice_id", &["-l"]).context("couldn't check for attached iPhones")?;
    let udids: BTreeSet<String> = raw
        .lines()
        .map(|l| l.split_whitespace().next().unwrap_or("").to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let mut devices = Vec::new();
    for udid in udids {
        devices.push(Device {
            name: ideviceinfo(&udid, "DeviceName"),
            product_type: ideviceinfo(&udid, "ProductType"),
            ios_version: ideviceinfo(&udid, "ProductVersion"),
            udid,
        });
    }
    Ok(devices)
}

/// Pick the device to use. Honors an explicit UDID, auto-picks when there's only
/// one, otherwise asks the user to choose.
pub fn select_device(devices: Vec<Device>, requested: Option<&str>) -> Result<Device> {
    if let Some(want) = requested {
        return devices
            .into_iter()
            .find(|d| d.udid == want)
            .ok_or_else(|| anyhow!("no iPhone with UDID {want} is plugged in"));
    }
    match devices.len() {
        0 => bail!("no iPhone found over USB. Plug in your jailbroken iPhone, unlock it, and tap Trust if it asks."),
        1 => Ok(devices.into_iter().next().unwrap()),
        _ => {
            let list = devices
                .iter()
                .map(|d| format!("  {}", d.summary()))
                .collect::<Vec<_>>()
                .join("\n");
            bail!("more than one iPhone is plugged in. Pick the one you want with --device <UDID>:\n{list}")
        }
    }
}
