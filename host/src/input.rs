//! Turns window events into device input messages. Coordinates are normalized
//! to [0, 1] of the screen so they don't depend on resolution or orientation.

use crate::protocol::MessageType;

/// A control message ready to send, built from window input.
pub struct InputFrame {
    pub msg_type: MessageType,
    pub payload: Vec<u8>,
}

impl InputFrame {
    pub fn new(msg_type: MessageType, payload: Vec<u8>) -> Self {
        Self { msg_type, payload }
    }
}

/// Map a window-pixel mouse position to normalized [0, 1] device coordinates,
/// accounting for the letterbox bars when the window and image aspect ratios
/// differ. Clamps to the image edges.
pub fn map_to_norm(
    mx: f32,
    my: f32,
    win_w: usize,
    win_h: usize,
    frame_w: usize,
    frame_h: usize,
) -> (f32, f32) {
    if frame_w == 0 || frame_h == 0 || win_w == 0 || win_h == 0 {
        return (0.0, 0.0);
    }
    let ww = win_w as f32;
    let wh = win_h as f32;
    let img_aspect = frame_w as f32 / frame_h as f32;
    let win_aspect = ww / wh;

    // size and position of the image area inside the window
    let (img_w, img_h, x_off, y_off) = if win_aspect > img_aspect {
        let w = wh * img_aspect;
        (w, wh, (ww - w) / 2.0, 0.0)
    } else {
        let h = ww / img_aspect;
        (ww, h, 0.0, (wh - h) / 2.0)
    };

    let nx = ((mx - x_off) / img_w).clamp(0.0, 1.0);
    let ny = ((my - y_off) / img_h).clamp(0.0, 1.0);
    (nx, ny)
}
