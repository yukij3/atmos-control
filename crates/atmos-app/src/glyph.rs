//! The menu-bar glyph (design/svg/glyph-{on,off}.svg) rasterized at startup into macOS
//! template images: AppKit uses the alpha as a mask and tints it for light and dark menu bars.
//! On = filled head (engine running), off = outline.

use resvg::{tiny_skia, usvg};
use rune::TrayIcon;

const GLYPH_ON: &str = include_str!("../../../design/svg/glyph-on.svg");
const GLYPH_OFF: &str = include_str!("../../../design/svg/glyph-off.svg");

/// Pixels per side: 2× of the 22 pt status-bar thickness (Rune sizes the icon to the bar).
const PX: u32 = 44;
/// The 22-unit viewBox drawn 18 pt tall inside the 22 pt box, as the SwiftUI app drew it.
const GLYPH_PT: f32 = 18.0;

pub fn tray_icon(on: bool) -> Option<TrayIcon> {
    let rgba = rasterize(if on { GLYPH_ON } else { GLYPH_OFF })?;
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

    #[test]
    fn both_glyphs_rasterize_with_ink() {
        for svg in [GLYPH_ON, GLYPH_OFF] {
            let rgba = rasterize(svg).expect("glyph rasterizes");
            assert_eq!(rgba.len(), (PX * PX * 4) as usize);
            let inked = rgba.as_chunks::<4>().0.iter().filter(|p| p[3] > 128).count();
            assert!(inked > 60, "glyph has visible pixels ({inked})");
            // The 18 pt glyph leaves a margin in the 22 pt box: the corners are empty.
            assert_eq!(rgba[3], 0);
        }
    }
}
