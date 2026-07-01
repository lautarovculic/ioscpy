//! Video decode. Turns a JPEG frame into a packed 0RGB buffer the window can
//! blit directly. The H.264 path produces the same `DecodedFrame` type.

use zune_jpeg::JpegDecoder;

/// A decoded frame: a `width * height` buffer of `0x00RRGGBB` pixels.
pub struct DecodedFrame {
    pub buf: Vec<u32>,
    pub width: usize,
    pub height: usize,
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
