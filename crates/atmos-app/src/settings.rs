//! The Settings window: an ordinary titled window, one instance, opened from the menu-bar menu,
//! the panel, or ⌘,. PLACEHOLDER content: an engine switch, a few commands and a readout of
//! the whole snapshot; the designed grouped form replaces `view`.

use std::rc::Rc;
use std::time::Duration;

use atmos_core::{CaptureChoice, ConfigField, MockPreset, OutputSelection, OutputType, Param};
use rune::tok::{self, space, type_};
use rune::{Cx, El, Key, KeyEvent, ScrollSpec, Tx, col, row, spacer, text};

use crate::shell::{Shell, Surface};
use crate::ui;

pub const SIZE: (f32, f32) = (480.0, 620.0);
pub const MIN_SIZE: (f32, f32) = (420.0, 480.0);

pub struct Settings {
    pub shell: Rc<Shell>,
    seen: u64,
}

impl Settings {
    pub fn new(shell: Rc<Shell>) -> Settings { Settings { shell, seen: 0 } }

    pub fn sync(&mut self) -> bool {
        let generation = self.shell.engine.generation();
        if generation == self.seen { return false; }
        self.seen = generation;
        true
    }
}

pub fn poll(s: &mut Settings, t: f64, tx: &mut Tx) -> bool {
    let engine = &s.shell.engine;
    engine.tick(s.shell.clock(t));
    if engine.wants_ticks() { tx.wake_after(Duration::from_millis(33)); }
    s.sync()
}

pub fn on_key(_: &mut Settings, ev: &KeyEvent, tx: &mut Tx) -> bool {
    match ev.key {
        Key::Command('w') => tx.close_window(),
        Key::Command('q') => tx.quit(),
        _ => return false,
    }
    true
}

pub fn on_visibility(s: &mut Settings, visible: bool, _: &mut Tx) {
    s.shell.set_surface_visible(Surface::Settings, visible);
}

pub fn on_close(s: &mut Settings, _: &mut Tx) {
    s.shell.set_surface_visible(Surface::Settings, false);
}

pub const SCENES: ui::Scenes<Settings> = &[
    ("playing", |s| s.shell.engine.mock_preset(MockPreset::Playing)),
    ("off", |s| s.shell.engine.mock_preset(MockPreset::Off)),
    ("starting", |s| s.shell.engine.mock_preset(MockPreset::Starting)),
    ("permission", |s| s.shell.engine.mock_preset(MockPreset::PermissionNeeded)),
    ("error", |s| s.shell.engine.mock_preset(MockPreset::Error)),
    ("speakers", |s| s.shell.engine.mock_preset(MockPreset::Speakers)),
    ("surround", |s| s.shell.engine.mock_preset(MockPreset::Surround)),
];

fn section(title: &str, t: &tok::Theme) -> El {
    text(title.to_owned()).font(type_::SECTION).color(t.text_secondary)
}

pub fn view(st: &Settings, cx: &mut Cx<Settings>) -> El {
    let dark = cx.system_dark();
    let t = tok::theme(dark);
    let engine = &st.shell.engine;
    let s = engine.snapshot();
    let c = &s.config;

    let engine_row = row().w_full().gap(space::S2).center_y()
        .child(col().gap(2.0)
            .child(text("Engine").font(type_::TITLE).color(t.text))
            .child(text(if s.is_on { format!("Routing system audio to {}", s.output_name) } else { "System audio plays normally".to_owned() })
                .font(type_::LABEL).color(t.text_secondary)))
        .child(spacer())
        .children(ui::mock_badge(engine, &t))
        .child(ui::switch("engine", "Engine", s.is_on, s.can_toggle(), dark).on_press(|st: &mut Settings| {
            let can = st.shell.engine.snapshot().can_toggle();
            if can { st.shell.engine.toggle(); }
        }));

    let mut capture = row().w_full().flex_wrap().gap(space::S2);
    for &choice in CaptureChoice::ALL {
        let available = choice.available(s.atmos_present, s.surround_driver_installed);
        let label = if choice == s.capture_choice { format!("● {}", choice.label()) } else { choice.label().to_owned() };
        capture = capture.child(
            row().key(format!("capture-{}", choice.raw())).role("button").label(choice.label()).h(26.0).px(space::S2)
                .center().radius(6.0).fill(t.control_off).opacity(if available && !s.busy { 1.0 } else { 0.45 })
                .child(text(label).font(type_::LABEL).color(t.text))
                .on_press(move |st: &mut Settings| {
                    let busy = st.shell.engine.snapshot().busy;
                    if !busy { st.shell.engine.set_capture_choice(choice); }
                }),
        );
    }

    let mut output_type = row().w_full().flex_wrap().gap(space::S2);
    for &ty in OutputType::ALL {
        let label = if ty == c.output_type { format!("● {}", ty.short_label()) } else { ty.short_label().to_owned() };
        output_type = output_type.child(
            row().key(format!("output-type-{}", ty.raw())).role("button").label(ty.label()).h(26.0).px(space::S2)
                .center().radius(6.0).fill(t.control_off)
                .child(text(label).font(type_::LABEL).color(t.text))
                .on_press(move |st: &mut Settings| st.shell.engine.set_and_apply(ConfigField::OutputType(ty))),
        );
    }

    let devices = s.outputs.iter().map(|d| {
        let mark = if s.selected_output == Some(d.id) { "●" } else { " " };
        format!("{mark} {} (id {}){}", d.name, d.id, if d.is_airpods { ", AirPods" } else { "" })
    }).collect::<Vec<_>>().join("\n");

    let tel = &s.telemetry;
    let readout = format!(
        "engine_status   {:?} ({})   busy {}   can_run {}\n\
         capture         {:?} / {:?}   driver {} / 12ch {}\n\
         output          {}   selected {}\n\
         hrtf            {:?} — {}\n\
         head tracking   {:?} ({})   pose {}   yaw {}\n\
         azimuth {}   elevation {}   distance {}\n\
         gain {}   width {}   reverb {} ({:?}, {})\n\
         algorithm {:?}   source {:?}   hrtf mode {:?}\n\
         meters          {:.3} / {:.3}   hold {:.3} / {:.3}\n\
         channels        {}\n\
         ring {}   captured {}   played {}\n\
         defaults        soundstage {}   rendering {}\n\
         disabled reason {}\n\
         advisory        {}\n\
         last error      {}",
        s.engine_status, s.engine_status_text, s.busy, s.can_run,
        s.capture_choice, s.capture_mode, s.atmos_present, s.surround_driver_installed,
        s.output_name, s.selected_output.map_or("follow default".into(), |id| id.to_string()),
        s.hrtf.state, s.hrtf.detail,
        s.head_track.state, s.head_track.text, tel.head_pose_live,
        atmos_core::format_number(tel.head_yaw.to_degrees() as f32, 0, true) + "°",
        Param::Azimuth.format(c.azimuth), Param::Elevation.format(c.elevation), Param::Distance.format(c.distance),
        Param::Gain.format(c.gain), Param::StereoWidth.format(c.stereo_width),
        if c.reverb_enabled { "on" } else { "off" }, c.reverb_room, Param::ReverbBlend.format(c.reverb_blend),
        c.algorithm, c.source_mode, c.hrtf_mode,
        tel.meter_l, tel.meter_r, tel.peak_hold_l, tel.peak_hold_r,
        if tel.channel_peaks.is_empty() { "—".to_owned() } else { tel.channel_peaks.iter().map(|p| format!("{p:.2}")).collect::<Vec<_>>().join(" ") },
        tel.ring_fill, tel.total_captured, tel.total_played,
        s.soundstage_is_default, s.rendering_is_default,
        s.personalization_disabled_reason.as_deref().unwrap_or("—"),
        s.music_atmos_advisory.as_deref().unwrap_or("—"),
        s.last_error.as_deref().unwrap_or("—"),
    );

    let actions = row().w_full().flex_wrap().gap(space::S2)
        .child(ui::button("head-tracking", if c.head_tracking { "Head tracking: on" } else { "Head tracking: off" }, &t)
            .on_press(|st: &mut Settings| {
                let on = st.shell.engine.snapshot().config.head_tracking;
                st.shell.engine.set_and_apply(ConfigField::HeadTracking(!on));
            }))
        .child(ui::button("follow-default", "Follow default output", &t)
            .on_press(|st: &mut Settings| st.shell.engine.select_output(OutputSelection::FollowDefault)))
        .child(ui::button("reset-soundstage", "Reset soundstage", &t).opacity(if s.soundstage_is_default { 0.45 } else { 1.0 })
            .on_press(|st: &mut Settings| st.shell.engine.reset_soundstage()))
        .child(ui::button("reset-rendering", "Reset rendering", &t).opacity(if s.rendering_is_default { 0.45 } else { 1.0 })
            .on_press(|st: &mut Settings| st.shell.engine.reset_rendering()));

    let mut body = col().w_full().padding(20.0).gap(space::S3)
        .child(engine_row);
    if s.permission_needed {
        body = body.child(row().w_full().flex_wrap().gap(space::S2)
            .child(ui::notice("Audio capture permission is needed.", &t))
            .child(ui::button("settings-open-privacy", "Open Privacy Settings", &t)
                .on_press(|st: &mut Settings| st.shell.engine.open_privacy_settings()))
            .child(ui::button("settings-try-again", "Try Again", &t)
                .on_press(|st: &mut Settings| st.shell.engine.retry_capture())));
    }
    if let Some(err) = &s.last_error {
        body = body.child(ui::error(err, dark));
    }
    let body = body.child(ui::separator(&t))
        .child(section("AUDIO CAPTURE", &t))
        .child(capture)
        .child(text(s.capture_choice.subtitle()).w_full().wrap().font(type_::LABEL).color(t.text_secondary))
        .child(section("OUTPUT TYPE", &t))
        .child(output_type)
        .child(section("OUTPUT DEVICES", &t))
        .child(text(devices).font(type_::LABEL.mono()).color(t.text))
        .child(actions)
        .child(ui::separator(&t))
        .child(section("SNAPSHOT (placeholder readout)", &t))
        .child(text(readout).w_full().wrap().font(type_::MONO_CAPTION.mono().features("'tnum' 1")).color(t.text));

    col().key("settings").w_full().h_full().fill(t.bg)
        .child(body.scroll(ScrollSpec::default()).grow(1.0).min_h(0.0))
}
