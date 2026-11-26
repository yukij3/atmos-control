//! The radar as a control, driven through a headless Rune runtime: dragging places the source
//! through the inverse distance scale, keys step it, and assistive technology reads its value.

use atmos_kit::stage::SourceMode;
use atmos_kit::{EditPhase, Radar, RadarGeometry, SourceEdit, Soundstage, Theme};
use rune::{App, AppSpec, Cx, El, Env, Key, KeyEvent, Mods, Runtime, Tx, el};

struct S {
    stage: Soundstage,
    edits: Vec<SourceEdit>,
}

fn init() -> S {
    S { stage: Soundstage::new(SourceMode::MonoPoint).azimuth(30.0), edits: Vec::new() }
}

fn view(s: &S, cx: &mut Cx<S>) -> El {
    let t = Theme::from_cx(cx);
    el().child(
        Radar::large(s.stage)
            .on_change(|s: &mut S, e: SourceEdit, _: &mut Tx| {
                s.stage.azimuth = e.azimuth;
                s.stage.distance = e.distance;
                s.edits.push(e);
            })
            .build(&t),
    )
}

fn runtime() -> Runtime<S> {
    let mut rt = App::new(AppSpec::new("radar", (320.0, 320.0), init, view)).headless_runtime((320.0, 320.0), Env::new(true, 2.0));
    rt.frame(0.0);
    rt
}

#[test]
fn drag_places_the_source_through_the_inverse_scale() {
    let mut rt = runtime();
    let (cx, cy) = rt.find("radar").expect("radar");
    let geo = RadarGeometry::large();
    // Right of the head (azimuth +90°), at the 2 m ring.
    let rho = geo.scale.rho(2.0);
    rt.pointer_down(cx + rho, cy);
    rt.frame(1.0 / 60.0);
    // Drag round to behind-left (azimuth −135°) at the 1 m ring.
    let r1 = geo.scale.rho(1.0);
    let a = (-135.0f32).to_radians();
    let (x, y) = (cx + r1 * a.sin(), cy - r1 * a.cos());
    rt.pointer_move(x, y);
    rt.frame(1.0 / 60.0);
    rt.pointer_up(x, y);
    rt.frame(1.0 / 60.0);

    let edits = &rt.state.edits;
    assert!(edits.len() >= 2, "{edits:?}");
    let first = edits[0];
    assert_eq!(first.phase, EditPhase::Begin);
    assert!((first.azimuth - 90.0).abs() < 0.5, "{first:?}");
    assert!((first.distance - 2.0).abs() < 0.02, "{first:?}");
    let last = *edits.last().unwrap();
    assert_eq!(last.phase, EditPhase::End);
    assert!((last.azimuth + 135.0).abs() < 0.5, "{last:?}");
    assert!((last.distance - 1.0).abs() < 0.02, "{last:?}");
}

#[test]
fn keys_step_azimuth_and_distance() {
    let mut rt = runtime();
    let (cx, cy) = rt.find("radar").expect("radar");
    // A click focuses the control (and places the source); then the keys step from there.
    rt.pointer_down(cx, cy - 100.0);
    rt.pointer_up(cx, cy - 100.0);
    rt.frame(0.0);
    let before = rt.state.stage;
    rt.key(KeyEvent { key: Key::Right, mods: Mods::default() });
    rt.frame(0.0);
    assert!((rt.state.stage.azimuth - (before.azimuth + 5.0)).abs() < 0.01, "{:?}", rt.state.stage);
    rt.key(KeyEvent { key: Key::Up, mods: Mods::default() });
    rt.frame(0.0);
    assert!(rt.state.stage.distance > before.distance, "{:?}", rt.state.stage);
}

#[test]
fn assistive_technology_reads_the_position() {
    let rt = runtime();
    let json = rt.accessibility_json().to_string();
    assert!(json.contains("Source position"), "{json}");
    assert!(json.contains("azimuth +30°"), "{json}");
    assert!(json.contains("distance 1.0 m"), "{json}");
}
