//! Small PLACEHOLDER building blocks for the shell's panel and settings windows. The designed
//! components (radar, gauge, meters, theme tokens) come from `crates/atmos-kit`.

use atmos_core::{Engine, EngineKind};
use rune::tok::{self, motion, radius, space, type_};
use rune::{El, col, el, row, spacer, text};

pub const PANEL_RADIUS: f32 = 16.0;

/// `--scene <name>` presets for headless renders (`AppSpec::scenes`).
pub type Scenes<S> = &'static [(&'static str, fn(&mut S))];

pub fn separator(t: &tok::Theme) -> El { el().w_full().h(1.0).fill(t.separator) }

/// "MOCK" when the mock engine runs, so a screenshot never passes for the real thing.
pub fn mock_badge(engine: &Engine, t: &tok::Theme) -> Option<El> {
    (engine.kind() == EngineKind::Mock).then(|| {
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

pub fn kv(label: &str, value: &str, t: &tok::Theme) -> El {
    row().w_full().gap(space::S2).center_y()
        .child(text(label.to_owned()).font(type_::BODY).color(t.text_secondary))
        .child(spacer())
        .child(text(value.to_owned()).font(type_::BODY).color(t.text).truncate())
}

/// A label and a tabular monospace value.
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
