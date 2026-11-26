//! The menu-bar panel: a borderless, nonactivating Liquid Glass window under the menu-bar
//! item. PLACEHOLDER content: it proves the bridge end to end (power, live status text,
//! numeric meters and head pose); the designed views replace `view` (and `ui`).

use std::rc::Rc;
use std::time::Duration;

use atmos_core::{CaptureChoice, MockPreset, Param, linear_to_db};
use rune::tok::{self, space, type_};
use rune::{Cx, El, Key, KeyEvent, SystemMaterial, Tx, col, row, spacer, text};

use crate::shell::{Shell, Surface};
use crate::ui;

pub struct Panel {
    pub shell: Rc<Shell>,
    /// The engine generation this window last drew.
    seen: u64,
}

impl Panel {
    pub fn new(shell: Rc<Shell>) -> Panel { Panel { shell, seen: 0 } }

    /// Catch up with the engine: true when the view must rebuild. Also keeps the menu-bar
    /// glyph current (this runs even while the panel is hidden).
    pub fn sync(&mut self) -> bool {
        let generation = self.shell.engine.generation();
        if generation == self.seen { return false; }
        self.seen = generation;
        self.shell.sync_tray();
        true
    }
}

/// Every frame and every wake: the mock's clock and the change check.
pub fn poll(p: &mut Panel, t: f64, tx: &mut Tx) -> bool {
    let engine = &p.shell.engine;
    engine.tick(p.shell.clock(t));
    if engine.wants_ticks() { tx.wake_after(Duration::from_millis(33)); }
    p.sync()
}

pub fn on_key(p: &mut Panel, ev: &KeyEvent, tx: &mut Tx) -> bool {
    match ev.key {
        Key::Escape => p.shell.hide_panel(),
        Key::Command(',') => p.shell.open_settings(),
        Key::Command('q') => tx.quit(),
        _ => return false,
    }
    true
}

/// Popover behaviour: clicking anywhere else hides the panel.
pub fn on_focus(p: &mut Panel, focused: bool, _: &mut Tx) {
    if !focused && p.shell.panel_visible() { p.shell.hide_panel(); }
}

pub fn on_visibility(p: &mut Panel, visible: bool, _: &mut Tx) {
    p.shell.set_surface_visible(Surface::Panel, visible);
}

/// `--scene <name>` for headless renders (mock engine).
pub const SCENES: ui::Scenes<Panel> = &[
    ("playing", |p| p.shell.engine.mock_preset(MockPreset::Playing)),
    ("off", |p| p.shell.engine.mock_preset(MockPreset::Off)),
    ("starting", |p| p.shell.engine.mock_preset(MockPreset::Starting)),
    ("permission", |p| p.shell.engine.mock_preset(MockPreset::PermissionNeeded)),
    ("error", |p| p.shell.engine.mock_preset(MockPreset::Error)),
    ("speakers", |p| p.shell.engine.mock_preset(MockPreset::Speakers)),
    ("surround", |p| p.shell.engine.mock_preset(MockPreset::Surround)),
];

pub fn view(p: &Panel, cx: &mut Cx<Panel>) -> El {
    let dark = cx.system_dark();
    let t = tok::theme(dark);
    let engine = &p.shell.engine;
    let s = engine.snapshot();
    let tel = &s.telemetry;

    let header = row().w_full().gap(space::S2).center_y()
        .child(text("atmos-control").font(type_::TITLE).color(t.text))
        .child(spacer())
        .children(ui::mock_badge(engine, &t))
        .child(ui::switch("power", "Engine", s.is_on, s.can_toggle(), dark).on_press(|p: &mut Panel| {
            let can = p.shell.engine.snapshot().can_toggle();
            if can { p.shell.engine.toggle(); }
        }));

    let status = col().w_full().gap(space::S1)
        .child(ui::kv("Engine", &s.engine_status_text, &t))
        .child(ui::kv("Output", &s.output_name, &t))
        .child(ui::kv("HRTF", &s.hrtf.short, &t).help(s.hrtf.detail.clone()))
        .child(ui::kv("Head tracking", &s.head_track.text, &t));

    let db = |x: f32| linear_to_db(x).map_or("\u{2212}\u{221e}".to_owned(), |d| atmos_core::format_number(d, 1, false));
    let readouts = col().w_full().gap(space::S1)
        .child(ui::mono_kv("meter-l", "L", &format!("{:>7} dB  peak {:>7}", db(tel.meter_l), db(tel.peak_hold_l)), &t))
        .child(ui::mono_kv("meter-r", "R", &format!("{:>7} dB  peak {:>7}", db(tel.meter_r), db(tel.peak_hold_r)), &t))
        .child(ui::mono_kv("head-yaw", "Head yaw", &if tel.head_pose_live {
            atmos_core::format_number(tel.head_yaw.to_degrees() as f32, 0, true) + "°"
        } else {
            "—".into()
        }, &t))
        .child(ui::mono_kv("source", "Source", &format!(
            "{} · {} · {}",
            Param::Azimuth.format(s.config.azimuth),
            Param::Elevation.format(s.config.elevation),
            Param::Distance.format(s.config.distance),
        ), &t));

    let mut notices = col().w_full().gap(space::S2);
    if s.permission_needed {
        notices = notices
            .child(ui::notice("Allow audio capture in System Settings ▸ Privacy & Security to spatialize system audio.", &t))
            .child(row().gap(space::S2)
                .child(ui::button("open-privacy", "Open Privacy Settings", &t).on_press(|p: &mut Panel| p.shell.engine.open_privacy_settings()))
                .child(ui::button("try-again", "Try Again", &t).on_press(|p: &mut Panel| p.shell.engine.retry_capture())));
    }
    if !s.can_run && !s.is_on {
        notices = notices
            .child(ui::notice(&format!("{} needs the atmos-control driver, which isn't installed.", s.capture_choice.label()), &t))
            .child(ui::button("use-personalized", "Use Personalized capture", &t)
                .on_press(|p: &mut Panel| p.shell.engine.set_capture_choice(CaptureChoice::Personalized)));
    }
    if let Some(advice) = &s.music_atmos_advisory {
        notices = notices.child(text(advice.clone()).w_full().wrap().font(type_::LABEL).color(t.text_secondary));
    }
    if let Some(err) = &s.last_error {
        notices = notices.child(ui::error(err, dark));
    }

    let footer = row().w_full().gap(space::S2)
        .child(ui::button("settings", "Settings…", &t).on_press(|p: &mut Panel| p.shell.open_settings()))
        .child(spacer())
        .child(ui::button("quit", "Quit", &t).on_press_tx(|_: &mut Panel, tx: &mut Tx| tx.quit()));

    let content = col().key("panel").w_full().h_full().padding(16.0).gap(space::S3)
        .child(header)
        .child(ui::separator(&t))
        .child(status)
        .child(ui::separator(&t))
        .child(readouts)
        .child(notices)
        .child(spacer())
        .child(footer);

    // Liquid Glass (NSGlassEffectView) on macOS 26+; the fill is the fallback where native
    // materials don't draw (headless renders, opaque windows).
    col().key("glass").w_full().h_full()
        .radius(ui::PANEL_RADIUS).continuous_corners()
        .fill(t.bg.alpha(0.92))
        .system_material(SystemMaterial::Glass)
        .child(content)
}
