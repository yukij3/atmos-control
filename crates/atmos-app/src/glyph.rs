//! The app's mark (design/svg/glyph-{on,off}.svg): a listener head between two pairs of
//! soundstage arcs, filled while the engine runs, hollow while it's off.
//!
//! - Menu bar: rasterized at startup into macOS template images (AppKit uses the alpha as a
//!   mask and tints it for light and dark menu bars), in three states: off, on, and off with a
//!   dot badge when the engine needs the user (permission denied, a failed start, a missing
//!   driver; audit L18), so a blocked engine never looks merely idle.
//! - Panel header: the same mark as Rune icons ([`MARK_ON`], [`MARK_OFF`]), tinted by the view.

use resvg::{tiny_skia, usvg};
use rune::{Icon, TrayIcon};

const GLYPH_ON: &str = include_str!("../../../design/svg/glyph-on.svg");
const GLYPH_OFF: &str = include_str!("../../../design/svg/glyph-off.svg");
/// The badge for [`TrayGlyph::Attention`], in the glyph's 22-unit box: top right, clear of the
/// outer arc by a stroke width.
const BADGE: &str = r#"<circle cx="19" cy="3.6" r="2.5" fill="currentColor"/>"#;

/// Pixels per side: 2× of the 22 pt status-bar thickness (Rune sizes the icon to the bar).
const PX: u32 = 44;
/// The 22-unit viewBox drawn 18 pt tall inside the 22 pt box, as the SwiftUI app drew it.
const GLYPH_PT: f32 = 18.0;

/// The panel header's mark while the engine runs (the bodies of design/svg/glyph-on.svg).
pub static MARK_ON: Icon = Icon {
    name: "atmos-mark-on",
    view: 22.0,
    body: r#"<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M15.43 5.33 A7.2 7.2 0 0 1 15.43 16.67"/><path d="M13.96 7.22 A4.8 4.8 0 0 1 13.96 14.78"/><path d="M6.57 5.33 A7.2 7.2 0 0 0 6.57 16.67"/><path d="M8.04 7.22 A4.8 4.8 0 0 0 8.04 14.78"/></g><circle cx="11" cy="11" r="2.7" fill="currentColor"/>"#,
};

/// The panel header's mark while the engine is off (design/svg/glyph-off.svg).
pub static MARK_OFF: Icon = Icon {
    name: "atmos-mark-off",
    view: 22.0,
    body: r#"<g fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M15.43 5.33 A7.2 7.2 0 0 1 15.43 16.67"/><path d="M13.96 7.22 A4.8 4.8 0 0 1 13.96 14.78"/><path d="M6.57 5.33 A7.2 7.2 0 0 0 6.57 16.67"/><path d="M8.04 7.22 A4.8 4.8 0 0 0 8.04 14.78"/><circle cx="11" cy="11" r="2.3"/></g>"#,
};

/// Which menu-bar glyph shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrayGlyph {
    Off,
    On,
    /// Off, and the engine needs the user.
    Attention,
}

impl TrayGlyph {
    pub const ALL: [TrayGlyph; 3] = [TrayGlyph::Off, TrayGlyph::On, TrayGlyph::Attention];

    pub fn for_snapshot(s: &atmos_core::Snapshot) -> TrayGlyph {
        if s.is_on {
            TrayGlyph::On
        } else if !s.busy && (s.permission_needed || s.last_error.is_some() || !s.can_run) {
            TrayGlyph::Attention
        } else {
            TrayGlyph::Off
        }
    }

    pub fn index(self) -> usize {
        self as usize
    }

    fn svg(self) -> String {
        match self {
            TrayGlyph::Off => GLYPH_OFF.to_owned(),
            TrayGlyph::On => GLYPH_ON.to_owned(),
            TrayGlyph::Attention => GLYPH_OFF.replacen("</svg>", &format!("  {BADGE}\n</svg>"), 1),
        }
    }
}

pub fn tray_icon(glyph: TrayGlyph) -> Option<TrayIcon> {
    let rgba = rasterize(&glyph.svg())?;
    Some(TrayIcon::rgba(PX, PX, rgba).template(true))
}

/// Straight (not premultiplied) RGBA rows.
fn rasterize(svg: &str) -> Option<Vec<u8>> {
    let tree = usvg::Tree::from_str(svg, &usvg::Options::default()).ok()?;
    let mut pixmap = tiny_skia::Pixmap::new(PX, PX)?;
    let view = tree.size().width().max(tree.size().height());
    let scale = PX as f32 / 22.0 * GLYPH_PT / view;
    let offset = (PX as f32 - view * scale) / 2.0;
    resvg::render(&tree, tiny_skia::Transform::from_row(scale, 0.0, 0.0, scale, offset, offset), &mut pixmap.as_mut());
    let mut rgba = pixmap.take();
    for px in rgba.as_chunks_mut::<4>().0 {
        let a = px[3] as u32;
        if a > 0 && a < 255 {
            for c in &mut px[..3] {
                *c = ((*c as u32 * 255 + a / 2) / a).min(255) as u8;
            }
        }
    }
    Some(rgba)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inked(rgba: &[u8]) -> usize {
        rgba.as_chunks::<4>().0.iter().filter(|p| p[3] > 128).count()
    }

    #[test]
    fn every_glyph_rasterizes_with_ink() {
        for g in TrayGlyph::ALL {
            let rgba = rasterize(&g.svg()).expect("glyph rasterizes");
            assert_eq!(rgba.len(), (PX * PX * 4) as usize);
            assert!(inked(&rgba) > 60, "{g:?} has visible pixels");
            // The 18 pt glyph leaves a margin in the 22 pt box: the top-left corner is empty.
            assert_eq!(rgba[3], 0);
        }
        // The badge adds ink to the off glyph, top right.
        let (off, attention) = (rasterize(&TrayGlyph::Off.svg()).unwrap(), rasterize(&TrayGlyph::Attention.svg()).unwrap());
        assert!(inked(&attention) > inked(&off) + 20);
    }

    #[test]
    fn the_header_marks_match_the_design_files() {
        for (icon, file) in [(&MARK_ON, GLYPH_ON), (&MARK_OFF, GLYPH_OFF)] {
            for d in icon.body.split("d=\"").skip(1).map(|s| s.split('"').next().unwrap()) {
                assert!(file.contains(d), "{} path {d} is in the design file", icon.name);
            }
        }
    }

    #[test]
    fn attention_only_when_idle_and_blocked() {
        use atmos_core::{Engine, MockPreset};
        let glyph = |p| TrayGlyph::for_snapshot(&Engine::mock(p).snapshot());
        assert_eq!(glyph(MockPreset::Playing), TrayGlyph::On);
        assert_eq!(glyph(MockPreset::Off), TrayGlyph::Off);
        assert_eq!(glyph(MockPreset::Starting), TrayGlyph::Off);
        assert_eq!(glyph(MockPreset::PermissionNeeded), TrayGlyph::Attention);
        assert_eq!(glyph(MockPreset::Error), TrayGlyph::Attention);
    }
}
