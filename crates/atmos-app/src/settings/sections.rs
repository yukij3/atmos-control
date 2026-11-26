//! The Settings sections, top to bottom: the engine status group, Output, Soundstage,
//! Personalization, Rendering (advanced, collapsed by default) and Levels. Every control reads
//! the engine's snapshot and is disabled, visibly and with its reason nearby, when it doesn't
//! apply (audit L10–L12, L15, L17, L19).
//!
//! Busy (a start, stop or rebuild in flight) disables only the restart-class controls: power,
//! audio capture and output device. Everything else stays live: the engine queues config,
//! source and reverb edits made while it starts and applies them when the start lands (audit
//! L2; `atmos_core.h`, "Edits made while busy are queued").

use atmos_core::{
    Algorithm, AttenuationCurve, CaptureChoice, CaptureMode, Config, ConfigField, Engine, EngineStatus, HeadTrackState,
    HrtfMode, HrtfState, OutputSelection, OutputType, Param, RoomType, Snapshot, SourceMode, SourceUpdate,
};
use atmos_kit::{ElevationGauge, Meters, Radar, Readout, SourceEdit, Soundstage, format, space};
use rune::{El, col, el, row};
use rune_kit::{Collapsible, Spinner};

use super::Settings;
use super::form::{Choice, ERROR, Form, INSET, Picker, SliderSpec, WARN};
use crate::ui;

// ── Status: power, permission, driver, errors (audit L17) ───────────────────────────────────

pub fn status(f: &Form, s: &Snapshot, engine: &Engine) -> El {
    let subtitle = match s.engine_status {
        EngineStatus::On => format!("Routing system audio to {}", s.output_name),
        EngineStatus::Starting => "Starting…".to_owned(),
        EngineStatus::Stopping => "Stopping…".to_owned(),
        EngineStatus::Off => "System audio plays normally".to_owned(),
    };
    let can = s.can_toggle();
    let mut sw = rune_kit::Switch::new(s.is_on).label("Engine").hide_label().disabled(!can);
    if can {
        sw = sw.on_toggle(|st: &mut Settings| {
            let can = st.shell.engine.snapshot().can_toggle();
            if can {
                st.shell.engine.toggle();
            }
        });
    }
    let tok = rune::tok::theme(f.t.dark);
    let trailing = row().key("engine-controls").gap(10.0).center_y()
        .children(s.busy.then(|| Spinner::new().size(14.0).build(&f.k).key("engine-spinner")))
        .children(ui::mock_badge(engine, &tok))
        .child(sw.build(&f.k).key("engine-switch"));
    let mut rows = vec![f.row("engine", "Engine", Some(&subtitle), true, trailing)];

    if s.permission_needed {
        rows.push(f.notice(
            "permission",
            &WARN,
            f.t.c.warn,
            "atmos-control needs permission to capture system audio.",
            Some("Allow it in System Settings ▸ Privacy & Security, then try again."),
            vec![
                f.button("Open Privacy Settings", |st: &mut Settings| st.shell.engine.open_privacy_settings()),
                f.button("Try Again", |st: &mut Settings| st.shell.engine.retry_capture()),
            ],
        ));
    }
    if !s.can_run && !s.is_on {
        let needs = match s.capture_choice {
            CaptureChoice::Surround => "Surround 7.1.4 capture needs the 12-channel atmos-control driver, which isn’t installed.",
            _ => "Stereo (virtual device) capture needs the atmos-control driver, which isn’t installed.",
        };
        rows.push(f.notice(
            "cant-run",
            &WARN,
            f.t.c.warn,
            "The engine can’t start with this capture mode.",
            Some(needs),
            vec![f.button("Use Personalized Capture", |st: &mut Settings| {
                st.shell.engine.set_capture_choice(CaptureChoice::Personalized)
            })],
        ));
    }
    if let Some(err) = &s.last_error {
        rows.push(f.notice("last-error", &ERROR, f.t.c.clip, err, None, Vec::new()));
    }
    col().key("status").role("group").label("Engine").w_full().child(f.group(rows))
}

// ── Output ──────────────────────────────────────────────────────────────────────────────────

pub fn output(f: &Form, s: &Snapshot) -> El {
    // Audio capture: modes that need the driver are greyed out with the reason in their title
    // (audit L10); no permanent driver note.
    let choices = CaptureChoice::ALL.iter().map(|&c| {
        let ok = c.available(s.atmos_present, s.surround_driver_installed);
        let title = if ok { c.label().to_owned() } else { format!("{} — driver not installed", c.label()) };
        Choice::new(c.raw().to_string(), title).enabled(ok || c == s.capture_choice)
    }).collect();
    let capture = Picker::new(s.capture_choice.raw().to_string(), s.capture_choice.label(), choices, |st, id| {
        if let Some(c) = id.parse().ok().and_then(CaptureChoice::from_raw) {
            st.shell.engine.set_capture_choice(c);
        }
    })
    .enabled(!s.busy);
    let mut rows = vec![f.picker_row("capture", "Audio capture", None, capture)];

    // Output device: Personalized follows the macOS output (a read-only name); the loopback
    // modes pick a sink.
    if s.capture_mode == CaptureMode::Tap {
        rows.push(f.value_row("device", "Output device", Some("Follows the macOS output"), &s.output_name));
    } else {
        let mut choices = vec![Choice::new("default", "Follow System Default")];
        choices.extend(s.outputs.iter().map(|d| Choice::new(d.id.to_string(), d.name.clone())));
        let (current, title, subtitle) = match s.selected_output {
            Some(id) => (id.to_string(), s.output_name.clone(), None),
            None => ("default".to_owned(), "System Default".to_owned(), Some(format!("Follows the macOS output: {}", s.output_name))),
        };
        let device = Picker::new(current, title, choices, |st, id| {
            let sel = if id == "default" { Some(OutputSelection::FollowDefault) } else { id.parse().ok().map(OutputSelection::Device) };
            if let Some(sel) = sel {
                st.shell.engine.select_output(sel);
            }
        })
        .separator_after_first()
        .enabled(!s.busy);
        rows.push(f.picker_row("device", "Output device", subtitle.as_deref(), device));
    }

    let c = &s.config;
    let types = OutputType::ALL.iter().map(|t| Choice::new(t.raw().to_string(), t.label())).collect();
    let output_type = Picker::new(c.output_type.raw().to_string(), c.output_type.label(), types, |st, id| {
        if let Some(t) = id.parse().ok().and_then(OutputType::from_raw) {
            st.shell.engine.set_and_apply(ConfigField::OutputType(t));
        }
    });
    rows.push(f.picker_row("output-type", "Output type", None, output_type));

    // The footnote: what the chosen capture mode trades (full width, so it reads in two lines),
    // then Apple Music's advice while the engine runs.
    let note = match &s.music_atmos_advisory {
        Some(advice) => format!("{} {advice}", capture_note(s.capture_choice)),
        None => capture_note(s.capture_choice).to_owned(),
    };
    f.section("output", "Output", rows, Some(&note))
}

/// The honest trade-off of each capture mode. Apple Music's Dolby Atmos advice is the engine's
/// (`music_atmos_advisory`, while running), so it isn't repeated here.
fn capture_note(c: CaptureChoice) -> &'static str {
    match c {
        CaptureChoice::Personalized => "Keeps your headphones as the system output, so Apple’s personalized Spatial Audio can engage. No driver needed.",
        CaptureChoice::Surround => "Captures all twelve 7.1.4 channels through the atmos-control driver. Rendering is generic: personalized HRTF can’t engage.",
        CaptureChoice::VirtualStereo => "Routes all audio through the atmos-control virtual device. Works with any output; rendering is generic.",
    }
}

// ── Soundstage ──────────────────────────────────────────────────────────────────────────────

fn kit_mode(m: SourceMode) -> atmos_kit::SourceMode {
    match m {
        SourceMode::DualPointStereo => atmos_kit::SourceMode::StereoPoints,
        SourceMode::AmbienceBedStereo => atmos_kit::SourceMode::StereoBed,
        SourceMode::PointSourceMono => atmos_kit::SourceMode::MonoPoint,
        SourceMode::Surround714 => atmos_kit::SourceMode::Surround714,
        SourceMode::SurroundBed714 => atmos_kit::SourceMode::SurroundBed714,
    }
}

fn stage(c: &Config) -> Soundstage {
    Soundstage { mode: kit_mode(c.source_mode), azimuth: c.azimuth, elevation: c.elevation, distance: c.distance, stereo_width: c.stereo_width }
}

/// What each source mode does (the picker's subtitle; the name is already on the button).
fn mode_note(m: SourceMode) -> &'static str {
    match m {
        SourceMode::DualPointStereo => "Left and right as two virtual speakers, ± the stereo width apart.",
        SourceMode::AmbienceBedStereo => "The whole stereo image as a far-field ambience bed.",
        SourceMode::PointSourceMono => "Both channels summed to one point source.",
        SourceMode::Surround714 => "Twelve channels at their 7.1.4 speaker positions.",
        SourceMode::SurroundBed714 => "The whole 7.1.4 field as a far-field ambience bed.",
    }
}

fn source(update: SourceUpdate) -> impl Fn(&mut Settings) {
    move |st: &mut Settings| st.shell.engine.set_source(update)
}

/// Distances read the same here as under the radar (`atmos_kit::format::metres`).
fn metres(v: f32) -> String { format::metres(v) }

fn reset_help(text: String) -> String { format!("Double-click to reset to {text}") }

pub fn soundstage(f: &Form, s: &Snapshot, d: &Config) -> El {
    let c = &s.config;
    let st = stage(c);
    let live = s.telemetry.head_pose_live;
    let yaw = live.then_some(s.telemetry.head_yaw as f32);

    // The instrument: the large radar (drag the source) and the elevation gauge, the readout
    // under the radar.
    let radar = Radar::large(st).key("radar").head_yaw(yaw).active(s.is_on)
        .on_change(|st: &mut Settings, e: SourceEdit, _| {
            // Every phase carries the values to show (Cancel: those from before the gesture).
            // Bed modes keep their distance: it's inert there.
            let bed = st.shell.engine.snapshot().config.source_mode.is_bed();
            st.shell.engine.set_source(SourceUpdate { azimuth: Some(e.azimuth), distance: (!bed).then_some(e.distance), ..Default::default() });
        })
        .build(&f.t);
    let geo = atmos_kit::RadarGeometry::large();
    let instrument = col().key("instrument").w_full().items_center().pt(14.0).pb(12.0).gap(2.0)
        .child(row().key("instrument-row")
            .child(radar)
            .child(el().w(space::RADAR_GAUGE))
            .child(ElevationGauge::large(st).key("elevation").active(s.is_on).build(&f.t)))
        .child(row().key("readout-row").w(geo.size + space::RADAR_GAUGE + atmos_kit::GaugeGeometry::beside(&geo).width)
            .child(row().w(geo.size).justify_center().child(Readout::new(st).key("readout").build(&f.t))));

    // Source mode: the 2-channel captures render the stereo modes, Surround the 7.1.4 ones.
    let modes: &[SourceMode] = if s.capture_choice == CaptureChoice::Surround {
        &[SourceMode::Surround714, SourceMode::SurroundBed714]
    } else {
        SourceMode::STEREO
    };
    let mode_choices = modes.iter().map(|m| Choice::new(m.raw().to_string(), m.label())).collect();
    let mode = Picker::new(c.source_mode.raw().to_string(), c.source_mode.label(), mode_choices, |st, id| {
        if let Some(m) = id.parse().ok().and_then(SourceMode::from_raw) {
            st.shell.engine.set_and_apply(ConfigField::SourceMode(m));
        }
    });

    let deg = |p: Param, v: f32| p.format(v);
    let az = SliderSpec {
        value: c.azimuth,
        min: -180.0,
        max: 180.0,
        step: 1.0,
        readout: deg(Param::Azimuth, c.azimuth),
        enabled: true,
        reset_help: reset_help(deg(Param::Azimuth, d.azimuth)),
        on_change: |st, v, _| st.shell.engine.set_source(SourceUpdate { azimuth: Some(v), ..Default::default() }),
        on_reset: |st| {
            let v = st.shell.engine.defaults().azimuth;
            source(SourceUpdate { azimuth: Some(v), ..Default::default() })(st)
        },
    };
    let el_spec = SliderSpec {
        value: c.elevation,
        min: -90.0,
        max: 90.0,
        step: 1.0,
        readout: deg(Param::Elevation, c.elevation),
        enabled: true,
        reset_help: reset_help(deg(Param::Elevation, d.elevation)),
        on_change: |st, v, _| st.shell.engine.set_source(SourceUpdate { elevation: Some(v), ..Default::default() }),
        on_reset: |st| {
            let v = st.shell.engine.defaults().elevation;
            source(SourceUpdate { elevation: Some(v), ..Default::default() })(st)
        },
    };
    // Distance: inert in the bed modes (audit L12); never past Max distance, where the engine
    // clamps it (audit L13).
    let bed = c.source_mode.is_bed();
    let dmax = c.distance_max.clamp(0.36, 6.0);
    let dist_note = if bed {
        Some("Not used by bed modes, which render far field.".to_owned())
    } else if c.distance_max < 6.0 {
        Some(format!("Limited by Max distance ({}).", metres(c.distance_max)))
    } else {
        None
    };
    let dist = SliderSpec {
        value: c.distance,
        min: 0.35,
        max: dmax,
        step: 0.01,
        readout: if bed { "far".to_owned() } else { metres(c.distance) },
        enabled: !bed,
        reset_help: reset_help(metres(d.distance)),
        on_change: |st, v, _| st.shell.engine.set_source(SourceUpdate { distance: Some(v), ..Default::default() }),
        on_reset: |st| {
            let v = st.shell.engine.defaults().distance;
            source(SourceUpdate { distance: Some(v), ..Default::default() })(st)
        },
    };
    let gain = SliderSpec {
        value: c.gain,
        min: -40.0,
        max: 12.0,
        step: 1.0,
        readout: Param::Gain.format(c.gain),
        enabled: true,
        reset_help: reset_help(Param::Gain.format(d.gain)),
        on_change: |st, v, _| st.shell.engine.set_source(SourceUpdate { gain: Some(v), ..Default::default() }),
        on_reset: |st| {
            let v = st.shell.engine.defaults().gain;
            source(SourceUpdate { gain: Some(v), ..Default::default() })(st)
        },
    };

    let mut rows = vec![
        instrument,
        f.picker_row("source-mode", "Source mode", Some(mode_note(c.source_mode)), mode),
        f.slider_row("azimuth", "Azimuth", None, az),
        f.slider_row("elevation", "Elevation", None, el_spec),
        f.slider_row("distance", "Distance", dist_note.as_deref(), dist),
        f.slider_row("gain", "Gain", None, gain),
    ];
    // Stereo width belongs to Stereo Points only.
    if c.source_mode == SourceMode::DualPointStereo {
        rows.push(f.slider_row("width", "Stereo width", None, SliderSpec {
            value: c.stereo_width,
            min: 0.0,
            max: 90.0,
            step: 1.0,
            readout: format!("±{}", Param::StereoWidth.format(c.stereo_width)),
            enabled: true,
            reset_help: reset_help(format!("±{}", Param::StereoWidth.format(d.stereo_width))),
            on_change: |st, v, _| st.shell.engine.set_source(SourceUpdate { stereo_width: Some(v), ..Default::default() }),
            on_reset: |st| {
                let v = st.shell.engine.defaults().stereo_width;
                source(SourceUpdate { stereo_width: Some(v), ..Default::default() })(st)
            },
        }));
    }
    rows.push(f.button_row(
        "reset-soundstage",
        "Reset Soundstage",
        "Position, gain and stereo width back to their defaults",
        !s.soundstage_is_default,
        |st: &mut Settings| st.shell.engine.reset_soundstage(),
    ));

    f.section("soundstage", "Soundstage", rows, Some("Drag the dot to place the source. Double-click a value to reset it."))
}

// ── Personalization ─────────────────────────────────────────────────────────────────────────

pub fn personalization(f: &Form, s: &Snapshot) -> El {
    let c = &s.config;
    let head_note = match s.head_track.state {
        HeadTrackState::Tracking => Some("Following your head with the headphones’ motion sensors."),
        HeadTrackState::Unavailable => Some("No head-motion data from this output. It needs AirPods or Beats with head tracking."),
        HeadTrackState::Off | HeadTrackState::Inactive => None,
    };
    let head = f.switch_row("head-tracking", "Head tracking", head_note, c.head_tracking, true, |st: &mut Settings| {
        let on = st.shell.engine.snapshot().config.head_tracking;
        st.shell.engine.set_and_apply(ConfigField::HeadTracking(!on));
    });

    // HRTF mode: disabled with the reason as its subtitle when personalization can't engage
    // (audit L19: the reason lives here, not in a second row).
    let reason = s.personalization_disabled_reason.as_deref();
    let label = |m: HrtfMode| if m == HrtfMode::Auto { "Automatic" } else { m.label() };
    let modes = [HrtfMode::Auto, HrtfMode::On, HrtfMode::Off].iter().map(|&m| Choice::new(m.raw().to_string(), label(m))).collect();
    let mode = Picker::new(c.hrtf_mode.raw().to_string(), label(c.hrtf_mode), modes, |st, id| {
        if let Some(m) = id.parse().ok().and_then(HrtfMode::from_raw) {
            st.shell.engine.set_and_apply(ConfigField::HrtfMode(m));
        }
    })
    .enabled(reason.is_none());

    // Status (property 3116): one word, and the reason only when the picker isn't already
    // saying it.
    let (word, live) = match s.hrtf.state {
        HrtfState::Personalized => ("Personalized", true),
        HrtfState::Generic => ("Generic", false),
        HrtfState::Inactive => ("Inactive", false),
    };
    let status_note = (s.hrtf.state == HrtfState::Generic && reason != Some(s.hrtf.detail.as_str())).then_some(s.hrtf.detail.as_str());
    let status = f.row("hrtf-status", "Status", status_note, true, f.status("hrtf-word", word, live));

    f.section(
        "personalization",
        "Personalization",
        vec![head, f.picker_row("hrtf-mode", "Personalized HRTF", reason, mode), status],
        Some("Turn Spatial Audio off for these headphones in Control Center while atmos-control runs, or audio is spatialized twice."),
    )
}

// ── Rendering (advanced, collapsed by default) ──────────────────────────────────────────────

pub fn rendering(f: &Form, s: &Snapshot, d: &Config, open: bool) -> El {
    // The whole header toggles; the chevron sits at its end, over the pop-up buttons' chevrons.
    let header = row().key("rendering-header").w_full().pl(INSET).pr(INSET - 8.0)
        .child(Collapsible::new("Rendering", open).arrow_always().arrow_end().arrow_size(13.0)
            .on_toggle(|st: &mut Settings| st.rendering_open = !st.rendering_open)
            .build(&f.k));
    let mut section = col().key("rendering").w_full().gap(6.0).child(header);
    if !open {
        return section.child(f.footnote("Algorithm, distance model and reverb."));
    }

    let c = &s.config;
    let algos = [Algorithm::Automatic, Algorithm::Hrtf, Algorithm::HrtfHq].iter().map(|a| Choice::new(a.raw().to_string(), a.label())).collect();
    let algorithm = Picker::new(c.algorithm.raw().to_string(), c.algorithm.label(), algos, |st, id| {
        if let Some(a) = id.parse().ok().and_then(Algorithm::from_raw) {
            st.shell.engine.set_and_apply(ConfigField::Algorithm(a));
        }
    });
    // The trade-off in secondary ink, not orange (audit V12).
    let algo_note = match c.algorithm {
        Algorithm::Automatic => "Apple’s renderer for the output type, the one personalized HRTF needs.",
        Algorithm::Hrtf | Algorithm::HrtfHq => "Personalized HRTF needs Automatic.",
    };

    // The distance model: inert in the bed modes (audit L12); the attenuation parameters only
    // matter while attenuation is on.
    let bed = c.source_mode.is_bed();
    let bed_note = bed.then_some("Not used by bed modes.");
    let atten = c.distance_attenuation && !bed;
    let curves = AttenuationCurve::ALL.iter().map(|a| Choice::new(a.raw().to_string(), a.label())).collect();
    let curve = Picker::new(c.attenuation_curve.raw().to_string(), c.attenuation_curve.label(), curves, |st, id| {
        if let Some(a) = id.parse().ok().and_then(AttenuationCurve::from_raw) {
            st.shell.engine.set_and_apply(ConfigField::AttenuationCurve(a));
        }
    })
    .enabled(atten);

    let rebuild = |p: Param, v: f32, dv: f32, enabled: bool, on_change: fn(&mut Settings, f32, bool), on_reset: fn(&mut Settings)| {
        let spec = p.spec();
        SliderSpec {
            value: v,
            min: spec.min,
            max: spec.max,
            step: if spec.decimals == 0 { 1.0 } else { 10f32.powi(-i32::from(spec.decimals)) },
            readout: if spec.unit == " m" { metres(v) } else { p.format(v) },
            enabled,
            reset_help: reset_help(if spec.unit == " m" { metres(dv) } else { p.format(dv) }),
            on_change,
            on_reset,
        }
    };
    let ref_spec = rebuild(Param::DistanceRef, c.distance_ref, d.distance_ref, atten,
        |st, v, done| apply(st, ConfigField::DistanceRef(v), done),
        |st| { let v = st.shell.engine.defaults().distance_ref; apply(st, ConfigField::DistanceRef(v), true) });
    let max_spec = rebuild(Param::DistanceMax, c.distance_max, d.distance_max, atten,
        |st, v, done| apply(st, ConfigField::DistanceMax(v), done),
        |st| { let v = st.shell.engine.defaults().distance_max; apply(st, ConfigField::DistanceMax(v), true) });
    let atten_spec = rebuild(Param::DistanceMaxAtten, c.distance_max_atten, d.distance_max_atten, atten,
        |st, v, done| apply(st, ConfigField::DistanceMaxAtten(v), done),
        |st| { let v = st.shell.engine.defaults().distance_max_atten; apply(st, ConfigField::DistanceMaxAtten(v), true) });

    // Reverb renders only under HRTF / HRTF HQ (audit L11): off under Automatic, with why.
    let reverb_ok = c.algorithm.supports_reverb();
    let reverb_note = (!reverb_ok).then_some("Needs the HRTF or HRTF HQ algorithm.");
    let room_ok = reverb_ok && c.reverb_enabled;
    let rooms = RoomType::ALL.iter().map(|r| Choice::new(r.raw().to_string(), r.label())).collect();
    let room = Picker::new(c.reverb_room.raw().to_string(), c.reverb_room.label(), rooms, |st, id| {
        if let Some(r) = id.parse().ok().and_then(RoomType::from_raw) {
            st.shell.engine.set_and_apply(ConfigField::ReverbRoom(r));
        }
    })
    .enabled(room_ok);
    let blend = SliderSpec {
        value: c.reverb_blend,
        min: 0.0,
        max: 100.0,
        step: 1.0,
        readout: Param::ReverbBlend.format(c.reverb_blend),
        enabled: room_ok,
        reset_help: reset_help(Param::ReverbBlend.format(d.reverb_blend)),
        on_change: |st, v, _| st.shell.engine.set_reverb_blend(v),
        on_reset: |st| {
            let v = st.shell.engine.defaults().reverb_blend;
            st.shell.engine.set_reverb_blend(v);
        },
    };

    let rows = vec![
        f.picker_row("algorithm", "Algorithm", Some(algo_note), algorithm),
        f.switch_row("itd", "Inter-aural delay", bed_note, c.interaural_delay, !bed, |st: &mut Settings| {
            let on = st.shell.engine.snapshot().config.interaural_delay;
            st.shell.engine.set_and_apply(ConfigField::InterauralDelay(!on));
        }),
        f.switch_row("attenuation", "Distance attenuation", None, c.distance_attenuation, !bed, |st: &mut Settings| {
            let on = st.shell.engine.snapshot().config.distance_attenuation;
            st.shell.engine.set_and_apply(ConfigField::DistanceAttenuation(!on));
        }),
        f.picker_row("curve", "Attenuation curve", None, curve),
        f.slider_row("distance-ref", "Reference distance", None, ref_spec),
        f.slider_row("distance-max", "Max distance", None, max_spec),
        f.slider_row("distance-atten", "Max attenuation", None, atten_spec),
        f.switch_row("reverb", "Room reverb", reverb_note, c.reverb_enabled, reverb_ok, |st: &mut Settings| {
            let on = st.shell.engine.snapshot().config.reverb_enabled;
            st.shell.engine.set_and_apply(ConfigField::ReverbEnabled(!on));
        }),
        f.picker_row("room", "Room size", None, room),
        f.slider_row("reverb-blend", "Reverb blend", None, blend),
        f.button_row(
            "reset-rendering",
            "Reset Rendering",
            "Algorithm, distance model and reverb back to their defaults",
            !s.rendering_is_default,
            |st: &mut Settings| st.shell.engine.reset_rendering(),
        ),
    ];
    section = section.child(col().key("rendering-content").role("region").label("Rendering").w_full().child(f.group(rows)));
    section
}

/// A rebuild-class field: shown at once, applied (a brief audio gap) on release.
fn apply(st: &mut Settings, field: ConfigField, done: bool) {
    st.shell.engine.set_field(field);
    if done {
        st.shell.engine.apply_config();
    }
}

// ── Levels ──────────────────────────────────────────────────────────────────────────────────

pub fn levels(f: &Form, s: &Snapshot, debug: bool) -> El {
    let tel = &s.telemetry;
    let surround = tel.channel_peaks.len() == 12;
    let meters = if surround {
        Meters::surround(&tel.channel_peaks).height(170.0).active(s.is_on).key("meters").build(&f.t)
    } else {
        Meters::stereo(tel.meter_l, tel.meter_r, tel.peak_hold_l, tel.peak_hold_r).height(150.0).active(s.is_on).key("meters").build(&f.t)
    };
    let meter_row = row().key("meter-row").w_full().justify_center().pt(14.0).pb(10.0).child(meters);

    let db = |x: f32| {
        let v = format::decibels(format::amplitude_db(x));
        v.trim_end_matches(" dB").to_owned()
    };
    let peak = if s.is_on {
        f.readout_row("peak", "Peak L / R", &format!("{} / {} dB", db(tel.peak_hold_l), db(tel.peak_hold_r)), true)
    } else {
        f.value_row("peak", "Peak L / R", None, "Engine off")
    };
    let mut rows = vec![meter_row, peak];
    if debug {
        rows.push(f.readout_row("ring", "Ring fill", &format!("{} frames", tel.ring_fill), true));
        rows.push(f.readout_row("counters", "Captured / played", &format!("{} / {}", tel.total_captured, tel.total_played), true));
    }
    f.section("levels", "Levels", rows, None)
}
