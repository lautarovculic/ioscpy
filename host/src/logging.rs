//! Small leveled logger gated by a global verbosity flag. No dependencies, clean
//! output by default, and the noisy stuff hidden behind `--debug`.

use std::sync::atomic::{AtomicBool, Ordering};

static DEBUG: AtomicBool = AtomicBool::new(false);

/// Turn on debug logging, set from `--debug`.
pub fn set_debug(on: bool) {
    DEBUG.store(on, Ordering::Relaxed);
}

pub fn debug_enabled() -> bool {
    DEBUG.load(Ordering::Relaxed)
}

/// Info line to stderr, so stdout stays clean for machine-readable output.
#[macro_export]
macro_rules! info {
    ($($arg:tt)*) => {{
        eprintln!("ioscpy: {}", format!($($arg)*));
    }};
}

/// Warning line, used for non-fatal failures so one feature dying doesn't take
/// down the session.
#[macro_export]
macro_rules! warn {
    ($($arg:tt)*) => {{
        eprintln!("ioscpy: warning: {}", format!($($arg)*));
    }};
}

/// Debug line, only printed when `--debug` is on.
#[macro_export]
macro_rules! debug {
    ($($arg:tt)*) => {{
        if $crate::logging::debug_enabled() {
            eprintln!("ioscpy: debug: {}", format!($($arg)*));
        }
    }};
}
