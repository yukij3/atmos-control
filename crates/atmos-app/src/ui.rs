//! Building blocks shared by the panel and settings windows: the rune-kit palette seeded from
//! atmos-kit's tokens, the MOCK badge rule, and small PLACEHOLDER helpers the settings
//! placeholder still uses. The designed components (radar, gauge, meters, theme tokens, icons)
//! come from `crates/atmos-kit`.

use atmos_core::{Engine, EngineKind};
use rune::tok::{self, motion, radius, space, type_};
use rune::{El, col, el, row, spacer, text};
use rune_kit::{Kit, PaletteSeed, SegmentedMetrics};

pub const PANEL_RADIUS: f32 = 16.0;

/// `--scene <name>` presets for headless renders (`AppSpec::scenes`).
pub type Scenes<S> = &'static [(&'static str, fn(&mut S))];

/// rune-kit's tokens for one window, derived from atmos-kit's (`Theme::kit_seed`: the window's
/// surface, the ink, instrument cyan), so kit switches, segmented controls and buttons share
/// the instruments' palette. Segmented controls are the compact macOS kind: 24 pt, the selected
/// pill inset in its groove.
pub fn kit(t: &atmos_kit::Theme, settings_window: bool) -> Kit {
    let (bg, fg, accent) = t.kit_seed(settings_window);
    let mut k = Kit::from_palette(PaletteSeed { bg, fg, accent });
    k.metrics.segmented = Some(SegmentedMetrics { height: 24.0, padding_x: 8.0, radius: 7.0, inset: 2.0, gap: 0.0 });
    // Switch knobs are white, as NSSwitch's are in both appearances (the seed would make them
    // the ink colour: near-black in light mode).
    let knob = if t.dark { atmos_kit::theme::srgb(0xf2f2f2) } else { rune::Color::WHITE };
    (k.c.knob, k.c.knob_on) = (knob, knob);
    k
}

/// `ATMOS_DOCS_SHOT=1`: a headless render for the docs (README screenshots from the mock
/// engine) leaves the MOCK badge out. Ignored in a real window, so the badge stays on by
/// default everywhere else.
pub fn docs_shot() -> bool {
    std::env::var_os("ATMOS_DOCS_SHOT").is_some_and(|v| v == "1") && rune::tooling::headless_run().is_some()
}

/// Whether to show "MOCK": the mock engine runs and this isn't a docs render.
pub fn mock_badge_visible(engine: &Engine) -> bool {
    engine.kind() == EngineKind::Mock && !docs_shot()
}

pub fn separator(t: &tok::Theme) -> El { el().w_full().h(1.0).fill(t.separator) }

/// "MOCK" when the mock engine runs, so a screenshot never passes for the real thing (see
/// [`mock_badge_visible`]).
pub fn mock_badge(engine: &Engine, t: &tok::Theme) -> Option<El> {
    mock_badge_visible(engine).then(|| {
        row().key("mock-badge").px(6.0).h(18.0).center().radius(radius::SM).fill(t.control_off)
            .child(text("MOCK").font(type_::SECTION).color(t.text_secondary))
    })
}

/// A switch; attach `on_press`. Reads as disabled (and ignores presses at the call site) when
/// `enabled` is false.
pub fn switch(key: &'static str, label: &'static str, on: bool, enabled: bool, dark: bool) -> El {
    let t = tok::theme(dark);
    let knob = el().size(18.0, 18.0).radius(9.0).fill(t.knob).absolute(if on { 18.0 } else { 2.0 }, 2.0);
    el().key(key).role("switch").label(label).checked(on).disabled(!enabled).focusable(enabled)
        .size(38.0, 22.0).radius(11.0)
        .fill(if on { tok::accent(0, dark) } else { t.control_off })
        .opacity(if enabled { 1.0 } else { 0.45 })
        .motion(motion::SNAPPY)
        .child(knob)
}

// `kv` and `mono_kv` served the placeholder panel; kept (unused here) while the settings
// window is rebuilt in parallel, so nothing it may call disappears under it.
#[allow(dead_code)]
pub fn kv(label: &str, value: &str, t: &tok::Theme) -> El {
    row().w_full().gap(space::S2).center_y()
        .child(text(label.to_owned()).font(type_::BODY).color(t.text_secondary))
        .child(spacer())
        .child(text(value.to_owned()).font(type_::BODY).color(t.text).truncate())
}

/// A label and a tabular monospace value.
#[allow(dead_code)]
pub fn mono_kv(key: &str, label: &str, value: &str, t: &tok::Theme) -> El {
    row().key(key.to_owned()).w_full().gap(space::S2).center_y()
        .child(text(label.to_owned()).font(type_::LABEL).color(t.text_secondary))
        .child(spacer())
        .child(text(value.to_owned()).font(type_::MONO_CAPTION.mono().features("'tnum' 1")).color(t.text))
}

/// A plain push button; attach `on_press`.
pub fn button(key: &'static str, label: &'static str, t: &tok::Theme) -> El {
    row().key(key).role("button").label(label).focusable(true)
        .h(26.0).px(space::S3).center().radius(radius::MD)
        .fill(t.control_off).hover(t.hover)
        .child(text(label).font(type_::LABEL).color(t.text))
}

pub fn notice(message: &str, t: &tok::Theme) -> El {
    col().w_full().padding(space::S2).radius(radius::MD).fill(t.control_off)
        .child(text(message.to_owned()).w_full().wrap().font(type_::LABEL).color(t.text))
}

pub fn error(message: &str, dark: bool) -> El {
    let red = if dark { rune::oklch(0.72, 0.17, 25.0) } else { rune::oklch(0.55, 0.2, 25.0) };
    text(message.to_owned()).key("last-error").w_full().wrap().font(type_::LABEL).color(red)
}
