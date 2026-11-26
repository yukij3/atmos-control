//! Every atmos-kit instrument in representative states, for eyeballing and headless snapshots.
//!
//! ```sh
//! cargo run --example gallery                                   # a window (drag the large 7.1.4 radar)
//! cargo run --example gallery -- --snap /tmp/atmos-kit/gallery-dark.png --theme dark --scale 2
//! cargo run --example gallery -- --snap /tmp/atmos-kit/gallery-light.png --theme light --scale 2
//! ```

#![forbid(unsafe_code)]

use atmos_kit::radar::RadarGeometry;
use atmos_kit::stage::SourceMode;
use atmos_kit::{ElevationGauge, Meters, Radar, Readout, SourceEdit, Soundstage, Theme, space, theme, ty};
use rune::{AppSpec, Cx, El, Tx, col, el, row, text};

/// dBFS to linear amplitude.
fn amp(db: f32) -> f32 {
    10f32.powf(db / 20.0)
}

struct Gallery {
    /// The settings radar's source, moved by dragging it.
    surround: Soundstage,
}

fn init() -> Gallery {
    Gallery { surround: Soundstage::new(SourceMode::Surround714).azimuth(15.0).distance(1.5) }
}

/// One panel's instrument block: radar + gauge, meters, readout under the radar.
fn panel_block(t: &Theme, caption: &str, stage: Soundstage, yaw_deg: Option<f32>, on: bool, levels: [f32; 4], key: &'static str) -> El {
    let geo = RadarGeometry::compact();
    let [l, r, hl, hr] = levels;
    col()
        .key(key)
        .w(300.0)
        .gap(space::S)
        .child(text(caption).font(ty::CAPTION).color(t.c.ink_secondary))
        .child(
            row()
                .child(Radar::compact(stage).head_yaw(yaw_deg.map(f32::to_radians)).active(on).build(t))
                .child(el().w(space::RADAR_GAUGE))
                .child(ElevationGauge::compact(stage).active(on).build(t))
                .child(el().w(space::GROUP))
                .child(Meters::stereo(l, r, hl, hr).active(on).height(geo.size).build(t)),
        )
        .child(row().w(geo.size).justify_center().child(Readout::new(stage).build(t)))
}

/// A stand-in for the menu-bar panel's surface.
fn panel(t: &Theme, key: &'static str, child: El) -> El {
    el().key(key).padding(space::PANEL_INSET).radius(12.0).fill(t.c.surface_panel).child(child)
}

fn view(s: &Gallery, cx: &mut Cx<Gallery>) -> El {
    let t = Theme::from_cx(cx);
    let silent = [0.0; 4];

    let row1 = row()
        .gap(space::XL)
        .child(panel(
            &t,
            "p-off",
            panel_block(&t, "Engine off · Stereo Points defaults", Soundstage::default(), None, false, silent, "b-off"),
        ))
        .child(panel(
            &t,
            "p-mono",
            panel_block(
                &t,
                "On · Mono Point +30° / 0° / 1.0 m · head −20°",
                Soundstage::new(SourceMode::MonoPoint).azimuth(30.0),
                Some(-20.0),
                true,
                [amp(-20.0), amp(-8.0), amp(-14.0), amp(-4.5)],
                "b-mono",
            ),
        ))
        .child(panel(
            &t,
            "p-stereo",
            panel_block(
                &t,
                "On · Stereo Points ±30° · el +20° · 2.0 m · head +10°",
                Soundstage::new(SourceMode::StereoPoints).elevation(20.0).distance(2.0),
                Some(10.0),
                true,
                [amp(-3.0), amp(0.0), amp(0.0), amp(0.0)],
                "b-stereo",
            ),
        ));

    let row2 = row()
        .gap(space::XL)
        .child(panel(
            &t,
            "p-bed",
            panel_block(
                &t,
                "On · Stereo Bed (far field) −40°",
                Soundstage::new(SourceMode::StereoBed).azimuth(-40.0),
                Some(0.0),
                true,
                [amp(-30.0), amp(-27.0), amp(-22.0), amp(-21.0)],
                "b-bed",
            ),
        ))
        .child(panel(
            &t,
            "p-sbed",
            panel_block(
                &t,
                "On · Surround Bed 7.1.4 · el +10°",
                Soundstage::new(SourceMode::SurroundBed714).elevation(10.0),
                None,
                true,
                [amp(-12.0), amp(-13.0), amp(-9.0), amp(-10.0)],
                "b-sbed",
            ),
        ))
        .child(panel(
            &t,
            "p-near",
            panel_block(
                &t,
                "On · Mono Point 180° at 0.35 m (nearest)",
                Soundstage::new(SourceMode::MonoPoint).azimuth(180.0).distance(0.35).elevation(-30.0),
                None,
                true,
                [amp(-60.5), amp(-45.0), amp(-50.0), amp(-38.0)],
                "b-near",
            ),
        ));

    // Settings: the large radar, draggable, beside the 12-channel meters.
    let peaks: Vec<f32> = [-14.0, -12.0, -9.0, -30.0, -20.0, -21.0, -26.0, -25.0, -4.0, -18.0, -0.0, -33.0].map(amp).to_vec();
    let surround = s.surround;
    let large = col()
        .key("s-surround")
        .gap(space::S)
        .child(text("Settings · Surround 7.1.4 · drag the source").font(ty::CAPTION).color(t.c.ink_secondary))
        .child(
            row()
                .child(
                    Radar::large(surround)
                        .key("radar-large")
                        .head_yaw(Some(12f32.to_radians()))
                        .active(true)
                        // Every phase carries the values to show; Cancel carries the ones from
                        // before the drag.
                        .on_change(|s: &mut Gallery, e: SourceEdit, _tx: &mut Tx| {
                            s.surround.azimuth = e.azimuth;
                            s.surround.distance = e.distance;
                        })
                        .build(&t),
                )
                .child(el().w(space::RADAR_GAUGE))
                .child(ElevationGauge::large(surround).key("elevation-large").build(&t))
                .child(el().w(space::XXL))
                .child(
                    col()
                        .gap(space::S)
                        .child(text("Levels").font(ty::SECTION).color(t.c.ink_secondary))
                        .child(Meters::surround(&peaks).height(RadarGeometry::LARGE - 22.0).key("meters-714").build(&t)),
                ),
        )
        .child(row().w(RadarGeometry::LARGE).justify_center().child(Readout::new(surround).key("readout-large").build(&t)));

    let stereo_large = Soundstage::new(SourceMode::StereoPoints).azimuth(-25.0).stereo_width(45.0).distance(0.35).elevation(-30.0);
    let large2 = col()
        .key("s-stereo")
        .gap(space::S)
        .child(text("Settings · Stereo Points ±45° at 0.35 m · head +35°").font(ty::CAPTION).color(t.c.ink_secondary))
        .child(
            row()
                .child(Radar::large(stereo_large).key("radar-large2").head_yaw(Some(35f32.to_radians())).build(&t))
                .child(el().w(space::RADAR_GAUGE))
                .child(ElevationGauge::large(stereo_large).key("elevation-large2").build(&t)),
        )
        .child(row().w(RadarGeometry::LARGE).justify_center().child(Readout::new(stereo_large).key("readout-large2").build(&t)));

    col()
        .key("root")
        .padding(space::XXL)
        .gap(space::XL)
        .fill(t.c.surface_window)
        .child(text("atmos-kit").font(ty::TITLE).color(t.c.ink))
        .child(text("Panel").font(ty::SECTION).color(t.c.ink_secondary))
        .child(row1)
        .child(row2)
        .child(t.divider())
        .child(text("Settings").font(ty::SECTION).color(t.c.ink_secondary))
        .child(row().gap(space::XXL * 2.0).child(large).child(large2))
}

fn main() {
    rune::run(AppSpec { families: theme::FAMILIES, ..AppSpec::new("atmos-kit gallery", (1140.0, 1120.0), init, view) });
}
