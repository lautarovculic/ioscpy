//! Apple-style hover toolbar for device controls. The original permanent
//! right-side strip consumed screen space and made the mirror look like a debug
//! utility. The replacement appears only near the top edge and keeps the phone
//! frame unobstructed the rest of the time.

use std::io::Cursor;
use std::sync::OnceLock;

pub const HOVER_ZONE: f32 = 76.0;
const TOP: f32 = 10.0;
const OUTER_PAD: f32 = 7.0;
const BUTTON: f32 = 40.0;
const GAP: f32 = 7.0;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Action {
    AppSwitcher,
    Home,
}

pub const BUTTONS: [Action; 2] = [Action::AppSwitcher, Action::Home];

fn toolbar_width() -> f32 {
    OUTER_PAD * 2.0 + BUTTON * BUTTONS.len() as f32 + GAP * (BUTTONS.len() - 1) as f32
}

fn toolbar_height() -> f32 {
    OUTER_PAD * 2.0 + BUTTON
}

fn bounds(window_w: f32) -> (f32, f32, f32, f32) {
    let w = toolbar_width();
    ((window_w - w - 12.0).max(8.0), TOP, w, toolbar_height())
}

pub fn hit_test(x: f32, y: f32, window_w: f32) -> Option<usize> {
    let (left, top, width, height) = bounds(window_w);
    if x < left || x >= left + width || y < top || y >= top + height {
        return None;
    }
    for index in 0..BUTTONS.len() {
        let x0 = left + OUTER_PAD + index as f32 * (BUTTON + GAP);
        let y0 = top + OUTER_PAD;
        if x >= x0 && x < x0 + BUTTON && y >= y0 && y < y0 + BUTTON {
            return Some(index);
        }
    }
    None
}

/// Draw the toolbar over an already rendered frame. `point_scale` converts
/// window points to pixels in the source canvas handed to minifb.
pub fn draw_into(
    buf: &mut [u32],
    stride: usize,
    width: usize,
    height: usize,
    point_scale: f32,
    pressed: Option<usize>,
) {
    if width == 0 || height == 0 || point_scale <= 0.0 {
        return;
    }
    let window_w = width as f32 / point_scale;
    let (left, top, toolbar_w, toolbar_h) = bounds(window_w);
    let x0 = (left * point_scale).round().max(0.0) as usize;
    let y0 = (top * point_scale).round().max(0.0) as usize;
    let x1 = ((left + toolbar_w) * point_scale).round().min(width as f32) as usize;
    let y1 = ((top + toolbar_h) * point_scale).round().min(height as f32) as usize;
    let radius = (16.0 * point_scale).max(1.0) as usize;
    fill_round_rect(
        buf, stride, width, height, x0, y0, x1, y1, radius, 0x001b1b1d, 218,
    );

    for (index, action) in BUTTONS.iter().enumerate() {
        let bx0 =
            ((left + OUTER_PAD + index as f32 * (BUTTON + GAP)) * point_scale).round() as usize;
        let by0 = ((top + OUTER_PAD) * point_scale).round() as usize;
        let bx1 = ((left + OUTER_PAD + index as f32 * (BUTTON + GAP) + BUTTON) * point_scale)
            .round() as usize;
        let by1 = ((top + OUTER_PAD + BUTTON) * point_scale).round() as usize;
        let color = if pressed == Some(index) {
            0x005f6064
        } else {
            0x00353639
        };
        fill_round_rect(
            buf,
            stride,
            width,
            height,
            bx0,
            by0,
            bx1,
            by1,
            (11.0 * point_scale).max(1.0) as usize,
            color,
            235,
        );
        draw_icon(buf, stride, width, height, bx0, by0, bx1, by1, *action);
    }
}

#[allow(clippy::too_many_arguments)]
fn fill_round_rect(
    buf: &mut [u32],
    stride: usize,
    width: usize,
    height: usize,
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
    radius: usize,
    color: u32,
    alpha: u8,
) {
    let x1 = x1.min(width);
    let y1 = y1.min(height);
    if x0 >= x1 || y0 >= y1 {
        return;
    }
    let r = radius.min((x1 - x0) / 2).min((y1 - y0) / 2);
    let rr = (r * r) as isize;
    for y in y0..y1 {
        for x in x0..x1 {
            let dx = if x < x0 + r {
                (x0 + r - x) as isize
            } else if x >= x1.saturating_sub(r) {
                (x - (x1 - r - 1)) as isize
            } else {
                0
            };
            let dy = if y < y0 + r {
                (y0 + r - y) as isize
            } else if y >= y1.saturating_sub(r) {
                (y - (y1 - r - 1)) as isize
            } else {
                0
            };
            if dx == 0 || dy == 0 || dx * dx + dy * dy <= rr {
                let px = &mut buf[y * stride + x];
                *px = blend_toward(*px, color, alpha);
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn draw_icon(
    buf: &mut [u32],
    stride: usize,
    width: usize,
    height: usize,
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
    action: Action,
) {
    let icon = icon_for(action);
    let box_w = x1.saturating_sub(x0);
    let box_h = y1.saturating_sub(y0);
    let size = (box_w.min(box_h) as f32 * 0.53).round().max(1.0) as usize;
    let ox = x0 + box_w.saturating_sub(size) / 2;
    let oy = y0 + box_h.saturating_sub(size) / 2;
    for dy in 0..size {
        let py = oy + dy;
        if py >= height {
            continue;
        }
        let sy = (dy * icon.h / size).min(icon.h - 1);
        for dx in 0..size {
            let px = ox + dx;
            if px >= width {
                continue;
            }
            let sx = (dx * icon.w / size).min(icon.w - 1);
            let alpha = icon.rgba[(sy * icon.w + sx) * 4 + 3];
            if alpha != 0 {
                let dst = &mut buf[py * stride + px];
                *dst = blend_toward(*dst, 0x00f4f4f5, alpha);
            }
        }
    }
}

fn blend_toward(bg: u32, fg: u32, alpha: u8) -> u32 {
    let a = alpha as u32;
    let mut out = 0u32;
    for shift in [0, 8, 16] {
        let bg_c = (bg >> shift) & 0xff;
        let fg_c = (fg >> shift) & 0xff;
        out |= ((bg_c * (255 - a) + fg_c * a) / 255) << shift;
    }
    out
}

struct IconImage {
    w: usize,
    h: usize,
    rgba: Vec<u8>,
}

fn decode_icon(bytes: &[u8]) -> IconImage {
    let decoder = png::Decoder::new(Cursor::new(bytes));
    let mut reader = decoder.read_info().expect("bundled icon is valid PNG");
    let mut rgba = vec![0; reader.output_buffer_size().expect("known icon size")];
    let info = reader.next_frame(&mut rgba).expect("bundled icon decodes");
    rgba.truncate(info.buffer_size());
    IconImage {
        w: info.width as usize,
        h: info.height as usize,
        rgba,
    }
}

struct Icons {
    home: IconImage,
    app_switcher: IconImage,
}

fn icon_for(action: Action) -> &'static IconImage {
    static ICONS: OnceLock<Icons> = OnceLock::new();
    let icons = ICONS.get_or_init(|| Icons {
        home: decode_icon(include_bytes!("../assets/icons/home.png")),
        app_switcher: decode_icon(include_bytes!("../assets/icons/appswitcher.png")),
    });
    match action {
        Action::Home => &icons.home,
        Action::AppSwitcher => &icons.app_switcher,
    }
}
