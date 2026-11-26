//! The panel's layout, top to bottom (DESIGN.md "Compact panel", audit (b)):
//!
//! 1. Header: the glyph and name, the power switch (the primary action).
//! 2. Status: Engine (the switch's text pair), Output, HRTF (with the honest reason when
//!    generic), Head tracking; then any notice with its recovery action.
//! 3. The soundstage, the hero: radar with the live head yaw, elevation gauge, L/R meters, the
//!    readout and its reset.
//! 4. Quick controls: output type, head tracking.
//! 5. Footer: Settings… ⌘, and Quit ⌘Q, one style.
//!
//! No cards: whitespace and hairlines separate the sections. One accent (instrument cyan) for
//! live state; orange and red only for problems, always beside a shape and words.

use atmos_core::{ConfigField, EngineStatus, OutputType, Snapshot, SourceMode};
use atmos_kit::radar::RadarGeometry;
use atmos_kit::stage::SourceMode as StageMode;
use atmos_kit::{ElevationGauge, Meters, Radar, Readout, Soundstage, Theme, icons, space, ty};
use rune::{Align, Cx, El, ScrollSpec, SystemMaterial, Tx, col, el, icon, row, spacer, text};
use rune_kit::{Button, ButtonVariant, ControlSize, IconButton, IconButtonVariant, Kit, Loader, ScrollBar, ScrollBarStyle, SegmentedControl, Switch};

use super::Panel;
use super::status::{Action, Line, Mark, Model, Notice, NoticeKind};
use crate::{glyph, ui};

/// Panel width in points: the 300 pt content column (radar 190 + 10 + gauge 31 + 20 + meters
/// 44 = 295) inside the 16 pt inset.
pub const WIDTH: f32 = 300.0 + 2.0 * space::PANEL_INSET;

/// Room between sections, either side of a hairline.
const SECTION: f32 = space::M;
/// Status row height (13 pt text on a 20 pt row).
const ROW_H: f32 = 20.0;
/// The shape cue's box, so values line up whatever the mark.
const MARK_BOX: f32 = 12.0;
/// A Regular rune-kit button's side padding: the footer's ghost buttons reach out by it.
const FOOTER_BLEED: f32 = 12.0;

pub fn view(p: &Panel, cx: &mut Cx<Panel>) -> El {
    let t = Theme::from_cx(cx);
    let k = ui::kit(&t, false);
    let engine = &p.shell.engine;
    let s = engine.snapshot();
    let model = Model::new(&s);

    let mut status = col().key("status").w_full().gap(space::XS).child(status_rows(&model, &t, &k));
    if let Some(advice) = &model.advisory {
        status = status.child(text(advice.clone()).key("advisory").w_full().wrap().font(ty::CAPTION).color(t.c.ink_secondary).pt(space::XXS));
    }
    for n in &model.notices {
        status = status.child(notice(n, &t, &k));
    }

    let content = col()
        .key("panel")
        .w_full()
        .px(space::PANEL_INSET)
        .pt(space::M + 2.0)
        .pb(space::S + 2.0)
        .child(header(p, &s, &t, &k))
        .child(el().h(space::M))
        .child(status)
        .child(divider(&t))
        .child(soundstage(&s, &t, &k))
        .child(divider(&t))
        .child(quick_controls(&s, &t, &k))
        .child(t.divider().mt(SECTION).mb(space::XS))
        .child(footer(&k));

    // Content taller than the screen below the menu bar (a long error on a small display)
    // scrolls, with its bar showing; at its usual height it never does (audit L21).
    let body = content
        .scroll(ScrollSpec::default())
        .max_h(p.shell.panel_max_height())
        .scroll_bar_styled(ScrollBarStyle::from_kit(&k).always_visible());

    // Liquid Glass (NSGlassEffectView) on macOS 26+; the fill is what draws where native
    // materials don't (headless renders, the README screenshots).
    col()
        .key("glass")
        .w_full()
        .radius(ui::PANEL_RADIUS)
        .continuous_corners()
        .fill(t.c.surface_panel)
        .system_material(SystemMaterial::Glass)
        .child(body)
}

fn divider(t: &Theme) -> El {
    t.divider().my(SECTION)
}

// ── Header ──────────────────────────────────────────────────────────────────────────────────

fn header(p: &Panel, s: &Snapshot, t: &Theme, k: &Kit) -> El {
    let on = s.is_on;
    // The switch shows what was asked for: on from the press, through Starting….
    let checked = matches!(s.engine_status, EngineStatus::On | EngineStatus::Starting);
    let glyph = icon(if on { &glyph::MARK_ON } else { &glyph::MARK_OFF }, 20.0)
        .key("glyph")
        .color(if on { t.c.accent } else { t.c.ink_secondary })
        .a11y_hidden();
    let power = Switch::new(checked)
        .label("Engine")
        .hide_label()
        .flat()
        .control_size(ControlSize::Small)
        .disabled(!s.can_toggle())
        .on_toggle(|p: &mut Panel| {
            let can = p.shell.engine.snapshot().can_toggle();
            if can { p.shell.engine.toggle(); }
        })
        .build(k)
        .key("power");
    row()
        .key("header")
        .w_full()
        .h(24.0)
        .center_y()
        .gap(space::S)
        .child(glyph)
        .child(text("atmos-control").key("title").font(ty::TITLE).color(t.c.ink).nowrap())
        .children(ui::mock_badge_visible(&p.shell.engine).then(|| mock_badge(t)))
        .child(spacer())
        .child(power)
}

/// "MOCK" beside the name whenever the mock engine draws, so no screenshot passes for the
/// real thing (`ATMOS_DOCS_SHOT=1` drops it from headless renders for the docs).
fn mock_badge(t: &Theme) -> El {
    row()
        .key("mock-badge")
        .h(16.0)
        .px(5.0)
        .center()
        .radius(4.0)
        .border(1.0, t.c.ink_tertiary)
        .label("Mock engine")
        .child(text("MOCK").font(rune::TextStyle { weight: 600.0, ..ty::TICK }).color(t.c.ink_secondary).a11y_hidden())
}

// ── Status ──────────────────────────────────────────────────────────────────────────────────

fn status_rows(m: &Model, t: &Theme, k: &Kit) -> El {
    col()
        .key("rows")
        .w_full()
        .gap(space::XXS)
        .child(status_row("engine", "Engine", &m.engine, t, k))
        .child(status_row("output", "Output", &m.output, t, k))
        .child(status_row("hrtf", "HRTF", &m.hrtf, t, k))
        .child(status_row("head-tracking", "Head tracking", &m.head, t, k))
}

fn status_row(key: &'static str, label: &'static str, line: &Line, t: &Theme, k: &Kit) -> El {
    let value = row()
        .key("value")
        .gap(6.0)
        .center_y()
        .shrink()
        .min_w(0.0)
        .children(line.mark.map(|m| mark(m, t, k)))
        .child(text(line.value.clone()).key("text").font(ty::BODY).color(t.c.ink).nowrap().truncate().shrink().min_w(0.0));
    let main = row()
        .key("line")
        .w_full()
        .h(ROW_H)
        .center_y()
        .gap(space::M)
        .child(text(label).key("label").font(ty::BODY).color(t.c.ink_secondary).nowrap())
        .child(spacer())
        .child(value);
    let mut r = col().key(key).w_full().role("group").label(format!("{label}: {}", line.value)).help(line.help.clone()).child(main);
    if let Some(reason) = &line.caption {
        // The honest reason, right under the value it explains.
        r = r.child(
            text(reason.clone())
                .key("reason")
                .w_full()
                .wrap()
                .align(Align::End)
                .font(ty::CAPTION)
                .color(t.c.ink_secondary)
                .pl(space::XXL * 2.0)
                .pb(space::XXS),
        );
    }
    r
}

/// The shape beside a status value: the radar's own marks (filled = live, ring = idle).
fn mark(m: Mark, t: &Theme, k: &Kit) -> El {
    let dot = |e: El| e.key("mark").size(7.0, 7.0).radius(3.5);
    let inner = match m {
        Mark::Live => dot(el()).fill(t.c.accent),
        Mark::Idle => dot(el()).border(1.25, t.c.ink_secondary),
        Mark::Busy => Loader::new().size(11.0).color(t.c.ink_secondary).build(k).key("mark"),
        Mark::Warn => icon(&icons::WARNING, 12.0).key("mark").color(t.c.warn),
        Mark::Error => icon(&icons::WARNING, 12.0).key("mark").color(t.c.clip),
    };
    row().key("mark-box").size(MARK_BOX, MARK_BOX).center().a11y_hidden().child(inner)
}

fn notice(n: &Notice, t: &Theme, k: &Kit) -> El {
    let (glyph, ink) = match n.kind {
        NoticeKind::Pending => (&icons::LOCK, t.c.ink_secondary),
        NoticeKind::Permission => (&icons::LOCK, t.c.warn),
        NoticeKind::Blocked => (&icons::WARNING, t.c.warn),
        NoticeKind::Failed => (&icons::WARNING, t.c.clip),
    };
    let mut body = col()
        .key("body")
        .grow(1.0)
        .shrink()
        .min_w(0.0)
        .gap(space::XXS)
        .child(text(n.title.clone()).key("title").w_full().wrap().font(ty::BODY).color(t.c.ink));
    if let Some(detail) = &n.detail {
        body = body.child(text(detail.clone()).key("detail").w_full().wrap().font(ty::CAPTION).color(t.c.ink_secondary));
    }
    if !n.actions.is_empty() {
        let mut actions = row().key("actions").gap(space::S).pt(space::XS);
        for &a in &n.actions {
            actions = actions.child(
                Button::new(a.label())
                    .control_size(ControlSize::Small)
                    .on_press(move |p: &mut Panel| run(p, a))
                    .build(k)
                    .key(a.key()),
            );
        }
        body = body.child(actions);
    }
    row()
        .key(n.key)
        .w_full()
        .items_start()
        .gap(space::S)
        .pt(space::S)
        .child(row().key("icon").size(MARK_BOX, 17.0).center().child(icon(glyph, 14.0).color(ink).a11y_hidden()))
        .child(body)
}

fn run(p: &mut Panel, a: Action) {
    let engine = &p.shell.engine;
    match a {
        Action::OpenPrivacy => engine.open_privacy_settings(),
        Action::RetryCapture => engine.retry_capture(),
        Action::StartAgain => engine.power_on(),
        Action::UsePersonalized => engine.set_capture_choice(atmos_core::CaptureChoice::Personalized),
    }
}

// ── Soundstage ──────────────────────────────────────────────────────────────────────────────

fn stage_mode(m: SourceMode) -> StageMode {
    match m {
        SourceMode::DualPointStereo => StageMode::StereoPoints,
        SourceMode::AmbienceBedStereo => StageMode::StereoBed,
        SourceMode::PointSourceMono => StageMode::MonoPoint,
        SourceMode::Surround714 => StageMode::Surround714,
        SourceMode::SurroundBed714 => StageMode::SurroundBed714,
    }
}

fn soundstage(s: &Snapshot, t: &Theme, k: &Kit) -> El {
    let c = &s.config;
    let stage = Soundstage {
        mode: stage_mode(c.source_mode),
        azimuth: c.azimuth,
        elevation: c.elevation,
        distance: c.distance,
        stereo_width: c.stereo_width,
    };
    let tel = &s.telemetry;
    let yaw = tel.head_pose_live.then_some(tel.head_yaw as f32);
    let on = s.is_on;
    let size = RadarGeometry::COMPACT;

    // Reset sits beside what it resets: the position the readout shows (plus gain and width,
    // which the tooltip names). Disabled when there is nothing to reset.
    let reset = IconButton::new(&icons::RESET)
        .variant(IconButtonVariant::GhostMuted)
        .control_size(ControlSize::Small)
        .label("Reset soundstage")
        .help("Reset soundstage: position, gain, width")
        .disabled(s.soundstage_is_default)
        .on_press(|p: &mut Panel| p.shell.engine.reset_soundstage())
        .build(k)
        .key("reset");
    let readout = row()
        .key("readout-row")
        .w(size)
        .h(20.0)
        .center_y()
        // The readout centres under the radar; the reset button hangs off its right.
        .child(el().w(20.0 + space::XS))
        .child(spacer())
        .child(Readout::new(stage).build(t))
        .child(spacer())
        .child(el().w(space::XS))
        .child(reset);

    row()
        .key("soundstage")
        .w_full()
        .items_start()
        .child(col().key("radar-col").gap(space::XS).child(Radar::compact(stage).head_yaw(yaw).active(on).build(t)).child(readout))
        .child(el().w(space::RADAR_GAUGE))
        .child(ElevationGauge::compact(stage).active(on).build(t))
        .child(spacer())
        .child(Meters::stereo(tel.meter_l, tel.meter_r, tel.peak_hold_l, tel.peak_hold_r).active(on).height(size).build(t))
}

// ── Quick controls ──────────────────────────────────────────────────────────────────────────

fn quick_controls(s: &Snapshot, t: &Theme, k: &Kit) -> El {
    let c = &s.config;
    let labels: Vec<&str> = OutputType::ALL.iter().map(|o| o.short_label()).collect();
    let selected = OutputType::ALL.iter().position(|&o| o == c.output_type);
    let mut output = SegmentedControl::new(&labels, selected)
        .label("Output type")
        .width(None)
        .on_pick(|p: &mut Panel, i: usize, _: &mut Tx| {
            if let Some(&o) = OutputType::ALL.get(i) {
                p.shell.engine.set_and_apply(ConfigField::OutputType(o));
            }
        });
    for (i, o) in OutputType::ALL.iter().enumerate() {
        output = output.help(i, o.label());
    }
    let head = c.head_tracking;
    let tracking = row()
        .key("head-tracking-row")
        .w_full()
        .h(ROW_H)
        .center_y()
        .child(text("Head tracking").key("label").font(ty::BODY).color(t.c.ink).nowrap())
        .child(spacer())
        .child(
            Switch::new(head)
                .label("Head tracking")
                .hide_label()
                .flat()
                .control_size(ControlSize::Mini)
                .on_toggle(|p: &mut Panel| {
                    let on = p.shell.engine.snapshot().config.head_tracking;
                    p.shell.engine.set_and_apply(ConfigField::HeadTracking(!on));
                })
                .build(k)
                .key("head-tracking"),
        );
    col().key("controls").w_full().gap(space::M).child(output.build(k).key("output-type")).child(tracking)
}

// ── Footer ──────────────────────────────────────────────────────────────────────────────────

fn footer(k: &Kit) -> El {
    let button = |label: &'static str, shortcut: &'static str| {
        Button::new(label).variant(ButtonVariant::Ghost).control_size(ControlSize::Regular).shortcut(shortcut).show_shortcut()
    };
    // Ghost buttons: their text lines up with the content edges, the hover fill runs past them
    // by the buttons' own padding.
    row()
        .key("footer")
        .w(300.0 + 2.0 * FOOTER_BLEED)
        .center_y()
        .mx(-FOOTER_BLEED)
        .child(button("Settings…", "cmd+,").on_press(|p: &mut Panel| p.shell.open_settings()).build(k).key("settings"))
        .child(spacer())
        .child(button("Quit", "cmd+q").on_press_tx(|_: &mut Panel, tx: &mut Tx| tx.quit()).build(k).key("quit"))
}
