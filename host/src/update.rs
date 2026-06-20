//! Best effort check for a newer ioscpy.
//!
//! The notice at launch is instant: it reads a small cached version file and never
//! waits on the network. A background thread refreshes that cache at most once a
//! day, so the check shows up from the next launch after a release. If the network
//! is down, the cache is empty, or the user opted out, nothing is shown.

use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const LATEST_URL: &str = "https://api.github.com/repos/lautarovculic/ioscpy/releases/latest";
const REFRESH_SECS: u64 = 24 * 60 * 60;

/// Where the last known release version is cached.
fn cache_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    let mut p = PathBuf::from(home);
    p.push("Library/Caches/ioscpy");
    let _ = fs::create_dir_all(&p);
    p.push("latest_version");
    Some(p)
}

/// Split "a.b.c" (with an optional leading v) into comparable numbers.
fn parse_ver(s: &str) -> Option<(u64, u64, u64)> {
    let s = s.trim().trim_start_matches('v');
    let mut parts = s.split('.');
    let major = parts.next()?.parse::<u64>().ok()?;
    let minor = parts
        .next()
        .and_then(|p| p.parse::<u64>().ok())
        .unwrap_or(0);
    let patch = parts
        .next()
        .and_then(|p| p.parse::<u64>().ok())
        .unwrap_or(0);
    Some((major, minor, patch))
}

/// True when `candidate` is a newer version than `current`.
fn newer(candidate: &str, current: &str) -> bool {
    match (parse_ver(candidate), parse_ver(current)) {
        (Some(a), Some(b)) => a > b,
        _ => false,
    }
}

fn read_cached() -> Option<String> {
    let text = fs::read_to_string(cache_path()?).ok()?;
    text.lines()
        .next()
        .map(|l| l.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// The alert line to print when a newer ioscpy is out, or None. Reads only the
/// cache, so it returns at once.
pub fn pending_notice(running: &str) -> Option<String> {
    let latest = read_cached()?;
    if newer(&latest, running) {
        Some(format!(
            "🚨 NEW VERSION 🚨 ioscpy {latest} is available. Update with: brew upgrade ioscpy"
        ))
    } else {
        None
    }
}

/// Notice for when the iPhone package is older than this Mac app. Uses the version
/// from the handshake, so it needs no network.
pub fn phone_behind_notice(daemon: &str, running: &str) -> Option<String> {
    if newer(running, daemon) {
        Some(format!(
            "Your iPhone is running an older ioscpy ({daemon}) than this Mac ({running}). \
             Update it from your Sileo or Zebra repo."
        ))
    } else {
        None
    }
}

/// Refresh the cached latest version in the background, at most once a day. Any
/// failure is ignored.
pub fn refresh_in_background() {
    thread::spawn(|| {
        let Some(path) = cache_path() else {
            return;
        };
        // Skip if the cache was written recently.
        if let Ok(meta) = fs::metadata(&path) {
            if let Ok(modified) = meta.modified() {
                if let Ok(age) = SystemTime::now().duration_since(modified) {
                    if age < Duration::from_secs(REFRESH_SECS) {
                        return;
                    }
                }
            }
        }
        let Some(tag) = fetch_latest_tag() else {
            return;
        };
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = fs::write(&path, format!("{tag}\n{now}\n"));
    });
}

/// Pull the latest release tag from GitHub with curl. None on any failure.
fn fetch_latest_tag() -> Option<String> {
    let out = Command::new("curl")
        .args(["-fsSL", "--max-time", "3", "-A", "ioscpy", LATEST_URL])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
    let tag = json
        .get("tag_name")?
        .as_str()?
        .trim()
        .trim_start_matches('v');
    if tag.is_empty() {
        None
    } else {
        Some(tag.to_string())
    }
}
