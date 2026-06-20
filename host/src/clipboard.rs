//! macOS clipboard access. Read/write text and watch the change count. The
//! session layer uses these to sync with the device without looping. Failures
//! here are non-fatal.

#[cfg(target_os = "macos")]
mod platform {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    /// UTI for plain UTF-8 text on the pasteboard.
    const UTF8_TEXT: &str = "public.utf8-plain-text";

    unsafe fn nsstring(s: &str) -> *mut Object {
        // strip NULs so the C string survives the round trip
        let cleaned = s.replace('\0', "");
        let c = std::ffi::CString::new(cleaned).unwrap_or_default();
        msg_send![class!(NSString), stringWithUTF8String: c.as_ptr()]
    }

    unsafe fn nsstring_to_rust(ns: *mut Object) -> String {
        if ns.is_null() {
            return String::new();
        }
        let utf8: *const std::os::raw::c_char = msg_send![ns, UTF8String];
        if utf8.is_null() {
            return String::new();
        }
        std::ffi::CStr::from_ptr(utf8)
            .to_string_lossy()
            .into_owned()
    }

    unsafe fn general() -> *mut Object {
        msg_send![class!(NSPasteboard), generalPasteboard]
    }

    /// Counter that bumps on every pasteboard change. Cheap to poll.
    pub fn change_count() -> i64 {
        unsafe {
            let pb = general();
            if pb.is_null() {
                return 0;
            }
            msg_send![pb, changeCount]
        }
    }

    /// Plain text on the pasteboard, if any.
    pub fn read_text() -> Option<String> {
        unsafe {
            let pb = general();
            if pb.is_null() {
                return None;
            }
            let typ = nsstring(UTF8_TEXT);
            let s: *mut Object = msg_send![pb, stringForType: typ];
            if s.is_null() {
                return None;
            }
            let r = nsstring_to_rust(s);
            if r.is_empty() {
                None
            } else {
                Some(r)
            }
        }
    }

    /// Replace the pasteboard with `text`. Returns the new change count so the
    /// caller can ignore the change it just made.
    pub fn write_text(text: &str) -> i64 {
        unsafe {
            let pb = general();
            if pb.is_null() {
                return 0;
            }
            let _: i64 = msg_send![pb, clearContents];
            let ns = nsstring(text);
            let typ = nsstring(UTF8_TEXT);
            let _: bool = msg_send![pb, setString: ns forType: typ];
            msg_send![pb, changeCount]
        }
    }
}

/// FNV-1a 64-bit over the UTF-8 bytes. Must match the device's hash exactly so
/// the two sides recognize each other's content and don't sync-loop.
pub fn hash_text(text: &str) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in text.as_bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// Biggest clipboard payload we'll sync, in bytes.
pub const MAX_CLIPBOARD_BYTES: usize = 1 << 20;

#[cfg(target_os = "macos")]
pub use platform::{change_count, read_text, write_text};

#[cfg(not(target_os = "macos"))]
pub fn change_count() -> i64 {
    0
}
#[cfg(not(target_os = "macos"))]
pub fn read_text() -> Option<String> {
    None
}
#[cfg(not(target_os = "macos"))]
pub fn write_text(_text: &str) -> i64 {
    0
}
