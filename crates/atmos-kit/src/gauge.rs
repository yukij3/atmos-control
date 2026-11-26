//! The elevation gauge: a slim arc beside the radar, −90° at the bottom, +90° at the top, its
//! ends level with the radar's outer ring and its middle level with the radar's head. A side-view
//! head mark sits at 0° (ear level); the source marks ride the arc.

use rune::{Align, El, LineCap, Path, Shape, canvas, el, text};

use crate::format;
use crate::geom::circle;
use crate::radar::{RadarGeometry, marker};
use crate::stage::{Layer, SourceMode, Soundstage, range};
use crate::theme::{Theme, ty};

/// Gauge layout for one radar size.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GaugeGeometry {
    /// Element height (the radar's size, so the two line up side by side).
    pub height: f32,
    /// Element width, labels included.
    pub width: f32,
    /// Half the arc's height: the radar's outer ring radius.
    pub half_span: f32,
    head_x: f32,
    head_radius: f32,
    chord_x: f32,
    bow: f32,
    tick: f32,
    dot: f32,
    labels: bool,
}

impl GaugeGeometry {
    /// Lines up with `radar` when both sit top-aligned in a row.
    pub fn beside(radar: &RadarGeometry) -> GaugeGeometry {
        let labels = radar.labels;
        let (head_x, head_radius, chord_x, bow, tick) =
            if labels { (6.0, 4.5, 24.0, 9.0, 6.0) } else { (4.0, 3.2, 15.0, 6.0, 4.0) };
        let dot = radar.dot - 2.0;
        let arc_right = chord_x + bow + tick;
        GaugeGeometry {
            height: radar.size,
            width: if labels { arc_right + 4.0 + 28.0 } else { arc_right + dot / 2.0 + 3.0 },
            half_span: radar.radius(),
            head_x,
            head_radius,
            chord_x,
            bow,
            tick,
            dot,
            labels,
        }
    }

    fn center_y(&self) -> f32 {
        self.height / 2.0
    }
    /// Circle through the arc's ends and middle: `(centre x, radius, half angle)`.
    fn circle(&self) -> (f32, f32, f32) {
        let (r, b) = (self.half_span, self.bow);
        let rho = (r * r + b * b) / (2.0 * b);
        (self.chord_x + b - rho, rho, (r / rho).clamp(-1.0, 1.0).asin())
    }
    /// The point on the arc at `radius_offset` from it for `elevation` degrees.
    fn point(&self, elevation: f32, radius_offset: f32) -> [f32; 2] {
        let (xc, rho, max) = self.circle();
        let psi = elevation.clamp(range::ELEVATION.0, range::ELEVATION.1) / 90.0 * max;
        let r = rho + radius_offset;
        [xc + r * psi.cos(), self.center_y() - r * psi.sin()]
    }
}

/// The elevation gauge.
pub struct ElevationGauge {
    stage: Soundstage,
    geo: GaugeGeometry,
    active: bool,
    key: &'static str,
}

impl ElevationGauge {
    /// Beside the panel radar (no labels).
    pub fn compact(stage: Soundstage) -> ElevationGauge {
        ElevationGauge::beside(stage, &RadarGeometry::compact())
    }
    /// Beside the settings radar (+90° / 0° / −90° labels).
    pub fn large(stage: Soundstage) -> ElevationGauge {
        ElevationGauge::beside(stage, &RadarGeometry::large())
    }
    pub fn beside(stage: Soundstage, radar: &RadarGeometry) -> ElevationGauge {
        ElevationGauge { stage, geo: GaugeGeometry::beside(radar), active: true, key: "elevation" }
    }
    /// Engine rendering (snapshot `is_on`); off draws neutral outlines.
    pub fn active(mut self, on: bool) -> Self {
        self.active = on;
        self
    }
    pub fn key(mut self, key: &'static str) -> Self {
        self.key = key;
        self
    }

    pub fn build(self, t: &Theme) -> El {
        let ElevationGauge { stage, geo, active, key } = self;
        let stage = stage.clamped();
        let mut root = el().key(key).size(geo.width, geo.height);
        root = root.child(canvas(scale(&geo, t)).key("scale").absolute(0.0, 0.0).size(geo.width, geo.height).a11y_hidden());

        if geo.labels {
            for (k, e) in [("el90", 90.0f32), ("el0", 0.0), ("el-90", -90.0)] {
                let [x, y] = geo.point(e, 0.0);
                let x = x + geo.tick + 4.0;
                root = root.child(
                    text(format::degrees(e))
                        .key(k)
                        .font(ty::TICK)
                        .color(t.c.ink_secondary)
                        .align(Align::Start)
                        .absolute(x, y - 5.5)
                        .size(28.0, 11.0)
                        .a11y_hidden(),
                );
            }
        }

        // Ear-level layer, and the 7.1.4 height layer 45° above it.
        let mut marks = vec![("srcE", Layer::Ear, stage.elevation)];
        if stage.mode.is_surround() {
            marks.push(("srcH", Layer::Height, (stage.elevation + 45.0).min(range::ELEVATION.1)));
        }
        for (k, layer, e) in marks {
            let [x, y] = geo.point(e, 0.0);
            let d = geo.dot;
            root = root.child(
                el().key(k)
                    .absolute(x - d / 2.0, y - d / 2.0)
                    .size(d, d)
                    .frame_motion(t.motion.source)
                    .a11y_hidden()
                    .child(marker(layer, d, t, active)),
            );
        }

        let spoken = match stage.mode {
            SourceMode::Surround714 | SourceMode::SurroundBed714 => format!(
                "Elevation {}, height layer {}",
                format::degrees(stage.elevation),
                format::degrees((stage.elevation + 45.0).min(90.0))
            ),
            _ => format!("Elevation {}", format::degrees(stage.elevation)),
        };
        root.role("img").label(spoken)
    }
}

/// The arc (a thin filled band), ticks at ±90°, ±45° and 0°, and the side-view head at 0°.
fn scale(geo: &GaugeGeometry, t: &Theme) -> Shape {
    let (xc, rho, max) = geo.circle();
    let cy = geo.center_y();
    let steps = 40;
    let at = |r: f32, i: usize| {
        let psi = -max + 2.0 * max * i as f32 / steps as f32;
        [xc + r * psi.cos(), cy - r * psi.sin()]
    };
    let band: Vec<[f32; 2]> = (0..=steps).map(|i| at(rho + 0.5, i)).chain((0..=steps).rev().map(|i| at(rho - 0.5, i))).collect();
    let mut shape = Shape::new().fill(band, t.c.grid_strong);
    for e in [-90.0f32, -45.0, 0.0, 45.0, 90.0] {
        let len = if e.abs() == 45.0 { geo.tick * 0.6 } else { geo.tick };
        shape = shape.line(geo.point(e, 0.5), geo.point(e, 0.5 + len), 1.0, LineCap::Butt, t.c.grid_strong);
    }
    // Ear level: a faint line from the head to the arc.
    let (hx, hr) = (geo.head_x, geo.head_radius);
    shape = shape.line([hx + hr * 1.7, cy], [geo.chord_x + geo.bow - 0.5, cy], 1.0, LineCap::Butt, t.c.grid);
    // Side-view head facing the arc (front).
    let head = circle(Path::new(), hx, cy, hr, 32).polygon(vec![
        [hx + hr * 0.75, cy - hr * 0.42],
        [hx + hr * 1.45, cy],
        [hx + hr * 0.75, cy + hr * 0.42],
    ]);
    shape.fill_path(&head, t.c.head)
}
