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
pub struct H264Decoder;

#[cfg(not(target_os = "macos"))]
impl H264Decoder {
    pub fn new() -> Option<Self> {
        None
    }
    pub fn decode(&mut self, _avcc: &[u8]) -> Decoded {
        Decoded::Failed
    }
}
