//! Right-side button panel mirroring the existing keyboard shortcuts. minifb
//! has no native widgets, so the panel is pixels drawn straight into the
//! window buffer; this module only knows geometry and drawing, not how to
//! send input (that stays in `window.rs`, next to the keyboard handlers it
//! mirrors).
//!
//! Icons are PNGs under `assets/icons/`, traced from the Lucide icon set
//! (https://lucide.dev, ISC license), embedded with `include_bytes!` and
//! decoded once, lazily, on first draw (see `icon_for`). To change an icon,
//! replace its PNG and rebuild — nothing else in this file needs to change.

use std::io::Cursor;
use std::sync::OnceLock;

/// Sidebar width in window points, before backing-scale.
pub const WIDTH: usize = 56;

const ROWS: usize = 10;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Home,
    Lock,
    AppSwitcher,
    Rotate,
    Back,
    SelectAll,
    Copy,
    Paste,
    Cut,
    Undo,
}

/// Top group is the device actions (Home/Back/App Switcher first, then
/// Lock/Rotate); bottom group mirrors Cmd/Ctrl+A/C/V/X/Z.
pub const BUTTONS: [Action; ROWS] = [
    Action::Home,
    Action::Back,
    Action::AppSwitcher,
    Action::Lock,
    Action::Rotate,
    Action::SelectAll,
    Action::Copy,
    Action::Paste,
    Action::Cut,
    Action::Undo,
];

/// Which button, if any, contains the point `(x, y)` local to the sidebar
/// (`x` in `[0, WIDTH)`, `y` in `[0, height)`, both in window points).
pub fn hit_test(x: f32, y: f32, height: f32) -> Option<usize> {
    if x < 0.0 || x >= WIDTH as f32 || y < 0.0 || y >= height {
        return None;
    }
    let row_h = height / ROWS as f32;
    let idx = (y / row_h) as usize;
    (idx < ROWS).then_some(idx)
}

const BG: u32 = 0x00_24_24_24;
const BTN: u32 = 0x00_3a_3a_3a;
const BTN_PRESSED: u32 = 0x00_55_55_55;
const ICON_COLOR: u32 = 0x00_e6_e6_e6;
const DIVIDER: u32 = 0x00_18_18_18;

/// Render the sidebar into the row `[x_off, x_off + w)` of `buf`, a
/// `stride`-wide by `h`-tall buffer that also holds the device frame next to
/// it. `w` is the sidebar's on-screen width (already scaled to match the
/// content buffer it sits beside). `pressed` highlights the button currently
/// held down, if any.
pub fn draw_into(buf: &mut [u32], stride: usize, x_off: usize, w: usize, h: usize, pressed: Option<usize>) {
    if w == 0 || h == 0 {
        return;
    }
    for y in 0..h {
        let row = y * stride + x_off;
        for x in 0..w {
            buf[row + x] = BG;
        }
    }
    let row_h = h as f32 / ROWS as f32;
    for (i, action) in BUTTONS.iter().enumerate() {
        let y0 = (i as f32 * row_h) as usize;
        let y1 = (((i + 1) as f32 * row_h) as usize).min(h);
        let color = if Some(i) == pressed { BTN_PRESSED } else { BTN };
        for y in y0..y1 {
            let row = y * stride + x_off;
            for x in 1..w.saturating_sub(1) {
                buf[row + x] = color;
            }
        }
        draw_icon(buf, stride, x_off, w, *action, y0, y1);
    }
    // Separator between the device-action group and the editing group.
    let sep_y = ((5.0 * row_h) as usize).min(h.saturating_sub(1));
    let row = sep_y * stride + x_off;
    for x in 0..w {
        buf[row + x] = DIVIDER;
    }
}

/// Nearest-neighbor sample the icon's alpha channel into the `[y0, y1)` row
/// of the button at column range `[0, w)`, alpha-blending each covered pixel
/// toward `ICON_COLOR` so anti-aliased edges from the source PNG carry over
/// instead of hard-thresholding to on/off.
fn draw_icon(buf: &mut [u32], stride: usize, x_off: usize, w: usize, action: Action, y0: usize, y1: usize) {
    let icon = icon_for(action);
    let size = (((y1 - y0).min(w) as f32) * 0.7) as usize;
    if size == 0 {
        return;
    }
    let local_x_off = w.saturating_sub(size) / 2;
    let y_off = y0 + (y1 - y0).saturating_sub(size) / 2;
    for dy in 0..size {
        let sy = (dy * icon.h / size).min(icon.h - 1);
        let py = y_off + dy;
        if py >= y1 {
            continue;
        }
        for dx in 0..size {
            let sx = (dx * icon.w / size).min(icon.w - 1);
            let a = icon.rgba[(sy * icon.w + sx) * 4 + 3];
            if a == 0 {
                continue;
            }
            let px = local_x_off + dx;
            if px >= w {
                continue;
            }
            let dst = &mut buf[py * stride + x_off + px];
            *dst = blend_toward(*dst, ICON_COLOR, a);
        }
    }
}

/// Linear blend of `bg` toward `fg` by `alpha` (0 = `bg`, 255 = `fg`), per
/// `0x00RRGGBB` channel.
fn blend_toward(bg: u32, fg: u32, alpha: u8) -> u32 {
    let a = alpha as u32;
    let mut out = 0u32;
    let mut shift = 0;
    while shift <= 16 {
        let bg_c = (bg >> shift) & 0xff;
        let fg_c = (fg >> shift) & 0xff;
        let v = (bg_c * (255 - a) + fg_c * a) / 255;
        out |= v << shift;
        shift += 8;
    }
    out
}

struct IconImage {
    w: usize,
    h: usize,
    rgba: Vec<u8>,
}

fn decode_icon(png_bytes: &[u8]) -> IconImage {
    let decoder = png::Decoder::new(Cursor::new(png_bytes));
    let mut reader = decoder.read_info().expect("bundled icon PNG is well-formed");
    let mut buf = vec![0u8; reader.output_buffer_size().expect("bundled icon PNG has a known size")];
    let info = reader.next_frame(&mut buf).expect("bundled icon PNG decodes");
    buf.truncate(info.buffer_size());
    IconImage { w: info.width as usize, h: info.height as usize, rgba: buf }
}

struct IconSet {
    home: IconImage,
    lock: IconImage,
    app_switcher: IconImage,
    rotate: IconImage,
    back: IconImage,
    select_all: IconImage,
    copy: IconImage,
    paste: IconImage,
    cut: IconImage,
    undo: IconImage,
}

/// Decodes all ten bundled icons once, on first sidebar draw, and keeps them
/// around for the life of the process. Looked up by name (not array index)
/// so the mapping survives `Action` or `BUTTONS` being reordered.
fn icon_for(action: Action) -> &'static IconImage {
    static ICONS: OnceLock<IconSet> = OnceLock::new();
    let icons = ICONS.get_or_init(|| IconSet {
        home: decode_icon(include_bytes!("../assets/icons/home.png")),
        lock: decode_icon(include_bytes!("../assets/icons/lock.png")),
        app_switcher: decode_icon(include_bytes!("../assets/icons/appswitcher.png")),
        rotate: decode_icon(include_bytes!("../assets/icons/rotate.png")),
        back: decode_icon(include_bytes!("../assets/icons/back.png")),
        select_all: decode_icon(include_bytes!("../assets/icons/selectall.png")),
        copy: decode_icon(include_bytes!("../assets/icons/copy.png")),
        paste: decode_icon(include_bytes!("../assets/icons/paste.png")),
        cut: decode_icon(include_bytes!("../assets/icons/cut.png")),
        undo: decode_icon(include_bytes!("../assets/icons/undo.png")),
    });
    match action {
        Action::Home => &icons.home,
        Action::Lock => &icons.lock,
        Action::AppSwitcher => &icons.app_switcher,
        Action::Rotate => &icons.rotate,
        Action::Back => &icons.back,
        Action::SelectAll => &icons.select_all,
        Action::Copy => &icons.copy,
        Action::Paste => &icons.paste,
        Action::Cut => &icons.cut,
        Action::Undo => &icons.undo,
    }
}
