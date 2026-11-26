//! Design tokens (DESIGN.md): system appearance driven, neutral ink, one accent ("instrument
//! cyan"), orange for warn, red for clip only. Flat colours; the only soft edge anywhere is the
//! live source dot's accent shadow. No gradients.
//!
//! Colours are authored in sRGB like AppKit's semantic colours (`labelColor`, …) and are
//! translucent ink over whatever surface the panel's vibrancy or the window gives, so they hold
//! on both. Rune windows blend in sRGB by default, which is how AppKit composites them.

use rune::color::srgb_decode;
use rune::{Anim, Color, Curve, Cx, Easing, El, Family, hairline};

/// SF Pro, the macOS system UI font. Rune loads `SFNS.ttf` for this name on macOS
/// (`rune-text` `system_fonts/core_text.rs`); elsewhere it falls back to the sans slot.
pub const SANS: Family = Family::Named("System Font");
/// SF Mono: AppKit's `monospacedSystemFont`, loaded from the system on first use, never bundled.
pub const MONO: Family = Family::SystemMono;

/// `AppSpec::families` for the app: the sans slot is SF Pro, the mono slot `ui-monospace`
/// (SF Mono). rune-kit controls then draw in the system font too.
pub const FAMILIES: (&str, &str) = ("System Font", "ui-monospace");

/// Type roles. Every numeric readout is SF Mono with tabular digits (SF Mono's digits are already
/// one width; `'tnum'` also lets Rune's live text swap digits without reshaping).
pub mod ty {
    use super::{MONO, SANS};
    use rune::TextStyle;

    /// The one panel title ("atmos-control").
    pub const TITLE: TextStyle = TextStyle::new(15.0, 600.0).family(SANS);
    /// A quiet section header, drawn in secondary ink. Not tracked, not all caps.
    pub const SECTION: TextStyle = TextStyle::new(11.0, 600.0).family(SANS);
    /// Body text.
    pub const BODY: TextStyle = TextStyle::new(13.0, 400.0).family(SANS);
    /// Control labels ("Head tracking").
    pub const CONTROL: TextStyle = TextStyle::new(13.0, 500.0).family(SANS);
    /// Subtitles and footnotes under a row, in secondary ink.
    pub const CAPTION: TextStyle = TextStyle::new(11.0, 400.0).family(SANS);
    /// Numeric readouts: `az +30° · el 0° · 1.0 m`, `−6.2 dB`.
    pub const READOUT: TextStyle = TextStyle::new(12.0, 400.0).family(MONO).features("'tnum' 1").lh(15.0);
    /// Scale labels on the meters, the gauge and the large radar.
    pub const TICK: TextStyle = TextStyle::new(9.0, 400.0).family(MONO).features("'tnum' 1").lh(11.0);
}

/// Spacing scale in points.
pub mod space {
    pub const XXS: f32 = 2.0;
    pub const XS: f32 = 4.0;
    pub const S: f32 = 8.0;
    pub const M: f32 = 12.0;
    pub const L: f32 = 16.0;
    pub const XL: f32 = 20.0;
    pub const XXL: f32 = 24.0;
    /// The least room between two instrument groups side by side: the radar + gauge pair and the
    /// meters (audit V4: the gauge sat 8 pt from the meter's dB labels).
    pub const GROUP: f32 = 20.0;
    /// Between the radar and its elevation gauge.
    pub const RADAR_GAUGE: f32 = 10.0;
    /// Panel content inset (a 332 pt panel leaves 300 pt: radar 190 + 10 + gauge 31 + 20 + meters 44).
    pub const PANEL_INSET: f32 = 16.0;
}

/// Ease-out quart, `cubic-bezier(0.25, 1, 0.5, 1)`: fast start, long quiet landing.
pub const EASE_OUT_QUART: Easing = Easing::cubic(0.25, 1.0, 0.5, 1.0);

/// The curves the instruments move on. Ease-out only; under Reduce Motion every one is instant
/// (Rune also lands rotations, offsets and layout at once under Reduce Motion by itself).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Motion {
    /// A source settling on a new azimuth, distance or elevation (~150 ms).
    pub source: Anim,
    /// The head silhouette following a new head-pose sample. Short, so it bridges the ~25 Hz
    /// pose samples without lagging the real head.
    pub head: Anim,
    /// A meter bar moving to a new level: light smoothing between ~15 Hz snapshots.
    pub meter: Anim,
}

impl Motion {
    pub const fn full() -> Motion {
        Motion {
            source: Anim::new(Curve::tween(0.15, EASE_OUT_QUART)),
            head: Anim::new(Curve::tween(0.09, EASE_OUT_QUART)),
            meter: Anim::new(Curve::tween(0.07, Easing::EASE_OUT)),
        }
    }
    pub const fn reduced() -> Motion {
        Motion { source: Anim::INSTANT, head: Anim::INSTANT, meter: Anim::INSTANT }
    }
}

/// Semantic colours for one appearance.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Palette {
    /// Labels, readout values (`labelColor`).
    pub ink: Color,
    /// Units, secondary status, scale labels (`secondaryLabelColor`).
    pub ink_secondary: Color,
    /// Inactive marks, separators between readout fields (`tertiaryLabelColor`).
    pub ink_tertiary: Color,
    /// Empty meter tracks (`quaternaryLabelColor`-ish fill).
    pub track: Color,
    /// Hairline dividers between sections.
    pub separator: Color,
    /// Faint inner distance rings.
    pub grid: Color,
    /// Outer ring, azimuth ticks, front notch, head chevron, gauge arc.
    pub grid_strong: Color,
    /// The listener head silhouette (radar and gauge).
    pub head: Color,
    /// Instrument cyan: engaged state, the live source dot. Tuned per appearance for at least
    /// 3:1 against the surface.
    pub accent: Color,
    /// The live source dot's soft shadow.
    pub accent_glow: Color,
    /// Faint accent: the stereo stage arc between L and R.
    pub accent_faint: Color,
    /// Meter at or above −6 dB.
    pub warn: Color,
    /// Meter peak at or above 0 dB only.
    pub clip: Color,
    /// Stand-in for the panel's vibrancy material (the gallery, or a fallback without it).
    pub surface_panel: Color,
    /// The settings window's background (`windowBackgroundColor`).
    pub surface_window: Color,
}

/// All tokens for one commit: appearance, accessibility preferences, colours, motion.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Theme {
    pub dark: bool,
    pub reduced_motion: bool,
    pub increased_contrast: bool,
    pub c: Palette,
    pub motion: Motion,
}

/// An sRGB `0xRRGGBB` colour.
pub fn srgb(hex: u32) -> Color {
    srgba(hex, 1.0)
}

/// An sRGB `0xRRGGBB` colour at alpha `a`.
pub fn srgba(hex: u32, a: f32) -> Color {
    let ch = |shift: u32| srgb_decode(((hex >> shift) & 0xff) as f32 / 255.0);
    Color { r: ch(16), g: ch(8), b: ch(0), a }
}

impl Theme {
    /// The theme a view should use: the window's light or dark appearance, the commit's Reduce
    /// Motion (`Cx::is_reduced_motion`: macOS's accessibility preference unless the view
    /// overrides it) and Increase Contrast.
    pub fn from_cx<S>(cx: &Cx<S>) -> Theme {
        Theme::new(cx.system_dark(), cx.is_reduced_motion(), cx.system_increased_contrast())
    }

    pub fn new(dark: bool, reduced_motion: bool, increased_contrast: bool) -> Theme {
        let hc = increased_contrast;
        // Ink is black or white at AppKit's label alphas, a step stronger under Increase Contrast.
        let (ink_rgb, ink_a, sec_a, ter_a, track_a, sep_a, grid_a, strong_a, head_a) = if dark {
            (0xffffff, 0.85, if hc { 0.70 } else { 0.55 }, if hc { 0.40 } else { 0.25 }, if hc { 0.16 } else { 0.10 },
             if hc { 0.22 } else { 0.10 }, if hc { 0.30 } else { 0.14 }, if hc { 0.60 } else { 0.38 }, if hc { 0.75 } else { 0.55 })
        } else {
            (0x000000, 0.85, if hc { 0.68 } else { 0.50 }, if hc { 0.42 } else { 0.26 }, if hc { 0.14 } else { 0.07 },
             if hc { 0.24 } else { 0.10 }, if hc { 0.28 } else { 0.12 }, if hc { 0.58 } else { 0.36 }, if hc { 0.70 } else { 0.50 })
        };
        let ink = |a: f32| srgba(ink_rgb, a);
        // Instrument cyan: DESIGN's rgb(0.34, 0.82, 0.86) on dark (9.2:1 on #1E1E1E). On light it is
        // 1.5:1 against the window, so light mode deepens it to #16909B (3.2:1 on #ECECEC, 3.8:1 on
        // white), the same hue. Increase Contrast deepens it again.
        let accent = match (dark, hc) {
            (true, false) => srgb(0x57d1db),
            (true, true) => srgb(0x7fe3eb),
            (false, false) => srgb(0x16909b),
            (false, true) => srgb(0x0b7681),
        };
        // System orange and red (NSColor.systemOrange / systemRed per appearance).
        let (warn, clip) = if dark { (srgb(0xff9f0a), srgb(0xff453a)) } else { (srgb(0xff9500), srgb(0xff3b30)) };
        let c = Palette {
            ink: ink(ink_a),
            ink_secondary: ink(sec_a),
            ink_tertiary: ink(ter_a),
            track: ink(track_a),
            separator: ink(sep_a),
            grid: ink(grid_a),
            grid_strong: ink(strong_a),
            head: ink(head_a),
            accent,
            accent_glow: accent.alpha(if dark { 0.55 } else { 0.40 }),
            accent_faint: accent.alpha(if dark { 0.34 } else { 0.30 }),
            warn,
            clip,
            surface_panel: if dark { srgb(0x2a2a2c) } else { srgb(0xf2f2f2) },
            surface_window: if dark { srgb(0x1e1e1e) } else { srgb(0xececec) },
        };
        Theme {
            dark,
            reduced_motion,
            increased_contrast,
            c,
            motion: if reduced_motion { Motion::reduced() } else { Motion::full() },
        }
    }

    /// The hairline that separates sections (no boxes, no cards).
    pub fn divider(&self) -> El {
        hairline(self.c.separator)
    }

    /// Opaque `(bg, fg, accent)` for seeding a rune-kit palette (`rune_kit::PaletteSeed`) so kit
    /// controls (switches, segmented controls, sliders) share these tokens.
    pub fn kit_seed(&self, settings_window: bool) -> (Color, Color, Color) {
        let bg = if settings_window { self.c.surface_window } else { self.c.surface_panel };
        let fg = if self.dark { srgb(0xe3e3e3) } else { srgb(0x262626) };
        (bg, fg, self.c.accent)
    }
}
