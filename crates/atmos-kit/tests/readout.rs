//! The readout keeps one width and still separators while its values change, and each label
//! sits against its value (no run of padding between them).

use atmos_kit::stage::SourceMode;
use atmos_kit::{Readout, Soundstage, Theme};
use rune::{App, AppSpec, Cx, El, ElementInfo, Env, el};

fn view(s: &Soundstage, cx: &mut Cx<Soundstage>) -> El {
    let t = Theme::from_cx(cx);
    el().child(Readout::new(*s).build(&t))
}

fn layout(stage: Soundstage) -> Vec<ElementInfo> {
    let mut rt = App::new(AppSpec::new("readout", (400.0, 60.0), Soundstage::default, view)).headless_runtime((400.0, 60.0), Env::new(true, 2.0));
    rt.update(move |s, _| *s = stage);
    rt.frame(0.0);
    rt.elements()
}

fn rect(els: &[ElementInfo], path_end: &str) -> [f32; 4] {
    els.iter().find(|e| e.path.ends_with(path_end)).unwrap_or_else(|| panic!("no {path_end}")).rect
}

#[test]
fn width_and_separators_hold_while_values_change() {
    let stages = [
        Soundstage::default(),
        Soundstage::new(SourceMode::MonoPoint).azimuth(-180.0).elevation(-90.0).distance(0.35),
        Soundstage::new(SourceMode::StereoPoints).azimuth(35.0).elevation(5.0).distance(2.4),
        Soundstage::new(SourceMode::StereoBed).azimuth(-7.0),
    ];
    let base = layout(stages[0]);
    for s in &stages[1..] {
        let els = layout(*s);
        let az = els.iter().find(|e| e.path.ends_with("az/field/value")).and_then(|e| e.text.clone());
        assert_eq!(az, Some(atmos_kit::format::degrees(s.azimuth)), "the stage reached the view");
        for key in ["readout", "readout/s1", "readout/s2"] {
            assert_eq!(rect(&els, key), rect(&base, key), "{key} moved for {s:?}");
        }
    }
}

#[test]
fn labels_sit_against_their_values() {
    let els = layout(Soundstage::default());
    let (label, value) = (rect(&els, "az/field/label"), rect(&els, "az/field/value"));
    // The label's text ends with its one no-break space; the value starts right after it.
    assert!((label[0] + label[2] - value[0]).abs() < 0.5, "label {label:?} value {value:?}");
}
