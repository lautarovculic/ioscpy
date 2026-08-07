//! Video decode. Turns a JPEG frame into a packed 0RGB buffer the window can
//! blit directly. The H.264 path produces the same `DecodedFrame` type.

use zune_jpeg::JpegDecoder;

/// A decoded frame: a `width * height` buffer of `0x00RRGGBB` pixels.
pub struct DecodedFrame {
    pub buf: Vec<u32>,
    pub width: usize,
    pub height: usize,
}

/// Fast content fingerprint for unique-frame accounting. Sampling a bounded grid
/// avoids hashing every pixel at high resolutions while remaining sensitive to
/// motion across the whole screen.
pub fn frame_fingerprint(frame: &DecodedFrame) -> u64 {
    let mut hash = 1469598103934665603u64;
    let rows = frame.height.min(16).max(1);
    let cols = frame.width.min(16).max(1);
    for gy in 0..rows {
        let y = gy * frame.height.saturating_sub(1) / rows.saturating_sub(1).max(1);
        for gx in 0..cols {
            let x = gx * frame.width.saturating_sub(1) / cols.saturating_sub(1).max(1);
            hash ^= u64::from(frame.buf[y * frame.width + x]);
            hash = hash.wrapping_mul(1099511628211);
        }
    }
    hash ^= frame.width as u64;
    hash = hash.wrapping_mul(1099511628211);
    hash ^ frame.height as u64
}

/// Clockwise quarter-turns needed to show a captured orientation upright
/// (1=portrait, 2=upsideDown, 3=landscapeLeft, 4=landscapeRight). These match the
/// device's touch-rotation labels, so display and touch stay in step.
pub fn upright_turns(orientation: u8) -> u8 {
    match orientation {
        2 => 2, // upside down
        3 => 1, // landscape left
        4 => 3, // landscape right
        _ => 0, // portrait or unknown, already upright
    }
}

/// Rotate a decoded frame `turns` clockwise quarter-turns (0..=3). 0 is a no-op,
/// so the portrait path costs nothing.
pub fn rotate_cw(frame: DecodedFrame, turns: u8) -> DecodedFrame {
    let (w, h) = (frame.width, frame.height);
    match turns & 3 {
        0 => frame,
        2 => {
            // 180°: reversing the row-major buffer maps (r,c) -> (H-1-r, W-1-c).
            let mut buf = frame.buf;
            buf.reverse();
            DecodedFrame {
                buf,
                width: w,
                height: h,
            }
        }
        1 => {
            // 90° CW: src(c,r) -> dst(col = H-1-r, row = c); dst is H×W.
            let (dw, dh) = (h, w);
            let mut buf = vec![0u32; dw * dh];
            for r in 0..h {
                let src_row = r * w;
                for c in 0..w {
                    buf[c * dw + (h - 1 - r)] = frame.buf[src_row + c];
                }
            }
            DecodedFrame {
                buf,
                width: dw,
                height: dh,
            }
        }
        _ => {
            // 270° CW (== 90° CCW): src(c,r) -> dst(col = r, row = W-1-c).
            let (dw, dh) = (h, w);
            let mut buf = vec![0u32; dw * dh];
            for r in 0..h {
                let src_row = r * w;
                for c in 0..w {
                    buf[(w - 1 - c) * dw + r] = frame.buf[src_row + c];
                }
            }
            DecodedFrame {
                buf,
                width: dw,
                height: dh,
            }
        }
    }
}

/// Pack a tightly-packed RGB888 buffer into the window's `0x00RRGGBB` layout.
/// `rgb.len()` must be at least `width * height * 3`; extra bytes are ignored.
pub fn pack_rgb888(rgb: &[u8], width: usize, height: usize) -> Vec<u32> {
    let mut buf = vec![0u32; width * height];
    for (i, px) in buf.iter_mut().enumerate() {
        let r = rgb[i * 3] as u32;
        let g = rgb[i * 3 + 1] as u32;
        let b = rgb[i * 3 + 2] as u32;
        *px = (r << 16) | (g << 8) | b;
    }
    buf
}

/// Decode a JPEG into a packed 0RGB buffer. Returns `None` on a bad frame.
/// Color JPEGs decode to RGB by default, which is what the packing expects.
pub fn decode_jpeg(jpeg: &[u8]) -> Option<DecodedFrame> {
    let mut decoder = JpegDecoder::new(jpeg);
    let pixels = decoder.decode().ok()?;
    let (width, height) = decoder.dimensions()?;

    if pixels.len() < width * height * 3 {
        return None;
    }

    let buf = pack_rgb888(&pixels, width, height);
    Some(DecodedFrame { buf, width, height })
}

#[cfg(test)]
mod tests {
    use super::{frame_fingerprint, DecodedFrame};

    #[test]
    fn fingerprint_is_stable_and_detects_content_changes() {
        let a = DecodedFrame {
            buf: vec![0x00112233; 64],
            width: 8,
            height: 8,
        };
        let mut b = DecodedFrame {
            buf: a.buf.clone(),
            width: 8,
            height: 8,
        };
        assert_eq!(frame_fingerprint(&a), frame_fingerprint(&b));
        b.buf[63] ^= 0x00ff00;
        assert_ne!(frame_fingerprint(&a), frame_fingerprint(&b));
    }
}
