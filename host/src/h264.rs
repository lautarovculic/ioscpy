//! Safe wrapper over the VideoToolbox shim in `h264_decoder.m`. H.264 is
//! stateful so frames must be fed in order, which is why the network reader
//! thread drives this and not the window thread.

use crate::video::DecodedFrame;

/// Result of decoding one frame.
pub enum Decoded {
    /// A picture is ready.
    Frame(DecodedFrame),
    /// Nothing yet, still waiting for a keyframe or parameter sets.
    Pending,
    /// Couldn't decode. Caller should ask for a fresh keyframe.
    Failed,
}

#[cfg(target_os = "macos")]
mod ffi {
    use std::os::raw::c_int;

    #[repr(C)]
    pub struct Decoder {
        _private: [u8; 0],
    }

    extern "C" {
        pub fn ioscpy_h264_decoder_new() -> *mut Decoder;
        pub fn ioscpy_h264_decoder_free(dec: *mut Decoder);
        pub fn ioscpy_h264_decoder_decode(
            dec: *mut Decoder,
            avcc: *const u8,
            len: usize,
            out_bgra: *mut *const u8,
            out_w: *mut c_int,
            out_h: *mut c_int,
        ) -> c_int;
    }
}

#[cfg(target_os = "macos")]
pub struct H264Decoder {
    inner: *mut ffi::Decoder,
}

#[cfg(target_os = "macos")]
impl H264Decoder {
    /// Make a decoder, or `None` if VideoToolbox setup failed.
    pub fn new() -> Option<Self> {
        let inner = unsafe { ffi::ioscpy_h264_decoder_new() };
        if inner.is_null() {
            None
        } else {
            Some(Self { inner })
        }
    }

    /// Decode one AVCC frame (4-byte length-prefixed NALs, may carry SPS/PPS).
    pub fn decode(&mut self, avcc: &[u8]) -> Decoded {
        let mut out_ptr: *const u8 = std::ptr::null();
        let mut w: i32 = 0;
        let mut h: i32 = 0;
        let rc = unsafe {
            ffi::ioscpy_h264_decoder_decode(
                self.inner,
                avcc.as_ptr(),
                avcc.len(),
                &mut out_ptr,
                &mut w,
                &mut h,
            )
        };
        match rc {
            1 if !out_ptr.is_null() && w > 0 && h > 0 => {
                let width = w as usize;
                let height = h as usize;
                // the shim owns this buffer until the next decode, so copy it
                // into a frame we own before returning
                let bgra = unsafe { std::slice::from_raw_parts(out_ptr, width * height * 4) };
                let mut buf = vec![0u32; width * height];
                for (i, px) in buf.iter_mut().enumerate() {
                    let b = bgra[i * 4] as u32;
                    let g = bgra[i * 4 + 1] as u32;
                    let r = bgra[i * 4 + 2] as u32;
                    *px = (r << 16) | (g << 8) | b;
                }
                Decoded::Frame(DecodedFrame { buf, width, height })
            }
            0 => Decoded::Pending,
            _ => Decoded::Failed,
        }
    }
}

#[cfg(target_os = "macos")]
impl Drop for H264Decoder {
    fn drop(&mut self) {
        unsafe { ffi::ioscpy_h264_decoder_free(self.inner) };
    }
}

#[cfg(not(target_os = "macos"))]
use openh264::{decoder::Decoder, formats::YUVSource};

#[cfg(not(target_os = "macos"))]
pub struct H264Decoder {
    inner: Decoder,
    // Reused between frames so the per-frame conversion is a copy, not an
    // allocation.
    annex_b: Vec<u8>,
    rgb: Vec<u8>,
}

#[cfg(not(target_os = "macos"))]
const H264_ANNEX_B_START: [u8; 4] = [0, 0, 0, 1];

/// Convert one AVCC sample (4-byte big-endian length, then NAL, repeated) into
/// the Annex-B form openh264 expects (start code, then NAL, repeated). Returns
/// `false` if the lengths don't add up, which means a malformed frame.
#[cfg(not(target_os = "macos"))]
fn avcc_to_annex_b(avcc: &[u8], out: &mut Vec<u8>) -> bool {
    out.clear();
    let mut i = 0;
    while i + 4 <= avcc.len() {
        let nal_len = u32::from_be_bytes([avcc[i], avcc[i + 1], avcc[i + 2], avcc[i + 3]]) as usize;
        i += 4;
        if nal_len == 0 || i + nal_len > avcc.len() {
            return false;
        }
        out.extend_from_slice(&H264_ANNEX_B_START);
        out.extend_from_slice(&avcc[i..i + nal_len]);
        i += nal_len;
    }
    i == avcc.len()
}

#[cfg(not(target_os = "macos"))]
impl H264Decoder {
    pub fn new() -> Option<Self> {
        Decoder::new().ok().map(|inner| Self {
            inner,
            annex_b: Vec::new(),
            rgb: Vec::new(),
        })
    }

    pub fn decode(&mut self, avcc: &[u8]) -> Decoded {
        if !avcc_to_annex_b(avcc, &mut self.annex_b) {
            return Decoded::Failed;
        }
        match self.inner.decode(&self.annex_b) {
            Ok(Some(yuv)) => {
                let (width, height) = yuv.dimensions();
                let needed = width * height * 3;
                if self.rgb.len() < needed {
                    self.rgb.resize(needed, 0);
                }
                yuv.write_rgb8(&mut self.rgb[..needed]);
                let buf = crate::video::pack_rgb888(&self.rgb, width, height);
                Decoded::Frame(DecodedFrame { buf, width, height })
            }
            Ok(None) => Decoded::Pending,
            Err(e) => {
                crate::warn!("h264 decode error: {e}");
                Decoded::Failed
            }
        }
    }
}
