//! Building blocks shared by the panel and settings windows: the rune-kit palette seeded from
//! atmos-kit's tokens, the MOCK badge rule, the panel's corner radius and the scene table
//! type. The designed components (radar, gauge, meters, theme tokens, icons) come from
//! `crates/atmos-kit`.

use atmos_core::{Engine, EngineKind};
use rune::tok::{self, radius, type_};
use rune::{El, row, text};
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

/// "MOCK" when the mock engine runs, so a screenshot never passes for the real thing (see
/// [`mock_badge_visible`]; the panel draws its own in atmos-kit tokens).
pub fn mock_badge(engine: &Engine, t: &tok::Theme) -> Option<El> {
    mock_badge_visible(engine).then(|| {
        row().key("mock-badge").px(6.0).h(18.0).center().radius(radius::SM).fill(t.control_off)
            .child(text("MOCK").font(type_::SECTION).color(t.text_secondary))
    })
}
