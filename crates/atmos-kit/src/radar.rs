//! The soundstage radar: a top-down view of the horizontal plane, front at 12 o'clock.
//!
//! World-locked: distance rings (1 m, 2 m, 6 m), azimuth ticks (±90°, 180°), the front notch and
//! every source marker. Head-locked: the listener silhouette and its front chevron, which turn
//! with the real head yaw, so head tracking shows as the head turning inside a still world.

use std::rc::Rc;

use rune::{Align, Color, Cursor, Drag, El, FillRule, Key, KeyEvent, LineCap, Path, Phase, Shape, Tx, canvas, el, text};

use crate::format;
use crate::geom::{arc_band, ellipse_path, thick_polyline};
use crate::stage::{Emitter, Layer, RadarScale, SourceMode, Soundstage, range, wrap_degrees};
use crate::theme::{Theme, ty};

/// Where a radar drag or key press puts the source.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SourceEdit {
    /// Degrees, −180…180. In multi-source modes this is the stage's azimuth (Stereo Points'
    /// midpoint, 7.1.4's centre channel).
    pub azimuth: f32,
    /// Metres, 0.35…6. Unchanged in bed modes, where distance is inert.
    pub distance: f32,
    pub phase: EditPhase,
}

/// Where an edit is in its gesture.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditPhase {
    /// Pointer down: the source jumps under the pointer.
    Begin,
    /// Pointer moved while held.
    Change,
    /// Pointer released, or a one-shot keyboard / assistive step.
    End,
    /// The gesture was cancelled (Escape, focus loss): the edit carries the values from before
    /// the gesture; put them back.
    Cancel,
}

/// Radar layout: sizes in points for one diameter. `compact` (panel) and `large` (settings)
/// share the distance scale's formula, so a position reads the same on both.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RadarGeometry {
    /// Width and height of the element.
    pub size: f32,
    /// Room outside the outer ring (front notch, glow, labels on the large radar).
    pub margin: f32,
    pub scale: RadarScale,
    /// Listener head radius.
    pub head_radius: f32,
    /// Source marker diameter (point modes).
    pub dot: f32,
    /// Source marker diameter when eleven 7.1.4 sources share the plane.
    pub dot_dense: f32,
    /// Ring, azimuth and L/R labels.
    pub labels: bool,
}

impl RadarGeometry {
    /// The panel radar: 190 pt.
    pub const COMPACT: f32 = 190.0;
    /// The settings radar: 300 pt.
    pub const LARGE: f32 = 300.0;

    pub fn compact() -> RadarGeometry {
        RadarGeometry::new(Self::COMPACT, false)
    }
    pub fn large() -> RadarGeometry {
        RadarGeometry::new(Self::LARGE, true)
    }

    /// Geometry for a `size`-point radar; `labels` adds ring and azimuth labels (and the margin
    /// they need).
    pub fn new(size: f32, labels: bool) -> RadarGeometry {
        let size = size.max(80.0);
        let margin = if labels { 30.0 } else { 10.0 };
        let radius = size / 2.0 - margin;
        let head_radius = (radius * 0.085).clamp(5.5, 11.0);
        let dot = if labels { 10.0 } else { 8.0 };
        // The head reaches about 1.45 r at the nose tip and 1.25 r at the ears (see `head`); the
        // clearance keeps a 0.35 m source's marker a few points off it in every direction.
        let clearance = head_radius * 1.45 + dot / 2.0 + 5.0;
        RadarGeometry {
            size,
            margin,
            scale: RadarScale { radius, clearance },
            head_radius,
            dot,
            dot_dense: if labels { 8.0 } else { 6.0 },
            labels,
        }
    }

    pub fn center(&self) -> f32 {
        self.size / 2.0
    }
    pub fn radius(&self) -> f32 {
        self.scale.radius
    }

    /// The source position under a point in the radar's own coordinates: azimuth (degrees,
    /// clockwise from front) and distance (metres, via the inverse scale).
    pub fn edit_at(&self, x: f32, y: f32) -> (f32, f32) {
        let c = self.center();
        let (dx, dy) = (x - c, y - c);
        let az = if dx.abs() < 1e-3 && dy.abs() < 1e-3 { 0.0 } else { dx.atan2(-dy).to_degrees() };
        (wrap_degrees(az), self.scale.distance(dx.hypot(dy)))
    }
}

type Attach = Box<dyn FnOnce(El, Soundstage, RadarGeometry) -> El>;

/// The soundstage radar.
///
/// ```ignore
/// let t = Theme::from_cx(cx);
/// // Panel: read-only.
/// Radar::compact(stage).head_yaw(pose).active(s.is_on).build(&t)
/// // Settings: drag the source.
/// Radar::large(stage).head_yaw(pose).active(s.is_on)
///     .on_change(|s: &mut App, e: SourceEdit, _tx| s.bridge.set_source(Some(e.azimuth), None, Some(e.distance)))
///     .build(&t)
/// ```
pub struct Radar {
    stage: Soundstage,
    geo: RadarGeometry,
    head_yaw: Option<f32>,
    active: bool,
    key: &'static str,
    attach: Option<Attach>,
}

impl Radar {
    /// The panel radar (190 pt, no labels).
    pub fn compact(stage: Soundstage) -> Radar {
        Radar::with_geometry(stage, RadarGeometry::compact())
    }
    /// The settings radar (300 pt, ring and azimuth labels).
    pub fn large(stage: Soundstage) -> Radar {
        Radar::with_geometry(stage, RadarGeometry::large())
    }
    pub fn with_geometry(stage: Soundstage, geo: RadarGeometry) -> Radar {
        Radar { stage, geo, head_yaw: None, active: true, key: "radar", attach: None }
    }

    /// The live head yaw in radians, positive = head turned right (clockwise seen from above, the
    /// azimuth convention). `None` when there's no live pose: the head faces front.
    pub fn head_yaw(mut self, radians: Option<f32>) -> Self {
        self.head_yaw = radians.filter(|r| r.is_finite());
        self
    }

    /// Whether the engine is rendering (snapshot `is_on`). Off, the sources draw as neutral
    /// outlines: a position, not a live source.
    pub fn active(mut self, on: bool) -> Self {
        self.active = on;
        self
    }

    /// The element's key (default `"radar"`); give each radar in a window its own.
    pub fn key(mut self, key: &'static str) -> Self {
        self.key = key;
        self
    }

    /// Makes the radar a control: dragging (or clicking) places the source, Left/Right step the
    /// azimuth by 5°, Up/Down step the distance, and assistive technology sets the azimuth.
    /// `f` gets each edit; send it to the engine (`set_source`, live, no rebuild).
    pub fn on_change<S: 'static>(mut self, f: impl Fn(&mut S, SourceEdit, &mut Tx) + 'static) -> Self {
        let f = Rc::new(f);
        self.attach = Some(Box::new(move |root: El, stage: Soundstage, geo: RadarGeometry| {
            let keeps_distance = stage.mode.is_bed();
            let (az0, d0) = (stage.azimuth, stage.distance);
            let edit = move |x: f32, y: f32, phase: EditPhase| {
                let (az, d) = geo.edit_at(x, y);
                SourceEdit { azimuth: az, distance: if keeps_distance { d0 } else { d }, phase }
            };
            let on_drag = {
                let f = f.clone();
                move |s: &mut S, d: &mut Drag, tx: &mut Tx| {
                    let e = match d.phase {
                        Phase::Down => edit(d.x, d.y, EditPhase::Begin),
                        Phase::Move => edit(d.x, d.y, EditPhase::Change),
                        Phase::Up if d.cancelled() => SourceEdit { azimuth: az0, distance: d0, phase: EditPhase::Cancel },
                        Phase::Up => edit(d.x, d.y, EditPhase::End),
                    };
                    f(s, e, tx);
                }
            };
            let on_step = {
                let f = f.clone();
                move |s: &mut S, delta: i32, tx: &mut Tx| {
                    let az = wrap_degrees(az0 + 5.0 * delta as f32);
                    f(s, SourceEdit { azimuth: az, distance: d0, phase: EditPhase::End }, tx);
                }
            };
            let on_set = {
                let f = f.clone();
                move |s: &mut S, v: f64, tx: &mut Tx| {
                    f(s, SourceEdit { azimuth: wrap_degrees(v as f32), distance: d0, phase: EditPhase::End }, tx);
                }
            };
            let on_key = move |s: &mut S, k: &KeyEvent, tx: &mut Tx| -> bool {
                let dir = match k.key {
                    Key::Up => 1.0,
                    Key::Down => -1.0,
                    _ => return false,
                };
                if keeps_distance {
                    return false;
                }
                // One step is 1/24 of the log scale: about 12.6% in distance.
                let t = RadarScale::fraction(d0) + dir / 24.0;
                f(s, SourceEdit { azimuth: az0, distance: RadarScale::at_fraction(t), phase: EditPhase::End }, tx);
                true
            };
            root.on_drag(on_drag)
                .on_step(on_step)
                .on_set_value(on_set)
                .on_key(on_key)
                .range_value(az0 as f64, range::AZIMUTH.0 as f64, range::AZIMUTH.1 as f64)
                .range_step(5.0)
                .cursor(Cursor::Crosshair)
        }));
        self
    }

    pub fn build(self, t: &Theme) -> El {
        let Radar { stage, geo, head_yaw, active, key, attach } = self;
        let stage = stage.clamped();
        let (s, c, r) = (geo.size, geo.center(), geo.radius());
        let emitters = stage.emitters();

        let mut root = el().key(key).size(s, s);

        // World layer: rings at real distances, the outer one stronger.
        for (i, metres) in [1.0f32, 2.0].into_iter().enumerate() {
            let rho = geo.scale.rho(metres);
            root = root.child(ring(if i == 0 { "ring1" } else { "ring2" }, c, rho, 1.0, t.c.grid));
        }
        root = root.child(ring("ring6", c, r, 1.0, t.c.grid_strong));
        root = root.child(canvas(world_marks(&geo, t)).key("world").absolute(0.0, 0.0).size(s, s).a11y_hidden());
        if geo.labels {
            root = root.children(world_labels(&geo, t));
        }

        // The stereo stage between L and R, turning with the stage azimuth.
        if stage.mode == SourceMode::StereoPoints && stage.stereo_width >= 1.0 {
            let rho = geo.scale.rho(stage.distance);
            let w = stage.stereo_width.to_radians();
            let color = if active { t.c.accent_faint } else { t.c.grid };
            let band = Shape::new().fill(arc_band(c, c, rho - 0.6, rho + 0.6, -w, w), color);
            root = root.child(
                el().key("stage")
                    .absolute(0.0, 0.0)
                    .size(s, s)
                    .rotate_motion(t.motion.source)
                    .rotate(stage.azimuth.to_radians())
                    .a11y_hidden()
                    .child(canvas(band).absolute(0.0, 0.0).size(s, s)),
            );
        }

        // Head layer: silhouette + chevron, turning with the real head pose.
        let yaw = head_yaw.unwrap_or(0.0);
        root = root.child(
            el().key("head")
                .absolute(0.0, 0.0)
                .size(s, s)
                .rotate_motion(t.motion.head)
                .rotate(yaw)
                .a11y_hidden()
                .child(canvas(head_marks(&geo, t)).absolute(0.0, 0.0).size(s, s)),
        );

        // Sources, world-locked: each on an arm turned to its azimuth, so a change of azimuth
        // travels along the arc (never through the head) and distance moves along the arm.
        let dense = emitters.len() > 2;
        for (i, e) in emitters.iter().enumerate() {
            root = root.child(source_arm(i, e, &stage, &geo, t, active, dense));
        }

        let spoken = describe(&stage, head_yaw);
        root = match attach {
            Some(attach) => attach(root, stage, geo)
                .label("Source position")
                .a11y_value(spoken)
                .focus_ring_for("ring6", 2.0, 3.0, t.c.accent.alpha(0.6))
                .focus_ring_radius(r + 3.0),
            None => root.role("img").label("Soundstage").description(spoken),
        };
        root
    }
}

/// A circle of `width` drawn as an element border (analytic, crisp, no polyline joints).
fn ring(key: &'static str, c: f32, rho: f32, width: f32, color: Color) -> El {
    el().key(key).absolute(c - rho, c - rho).size(2.0 * rho, 2.0 * rho).radius(rho).border(width, color).a11y_hidden()
}

/// Ticks at ±90° and 180°, and the front notch at 0°, all world-locked.
fn world_marks(geo: &RadarGeometry, t: &Theme) -> Shape {
    let (c, r) = (geo.center(), geo.radius());
    let tick = if geo.labels { 7.0 } else { 6.0 };
    let mut shape = Shape::new();
    for deg in [90.0f32, 180.0, 270.0] {
        let a = deg.to_radians();
        let (sx, sy) = (a.sin(), -a.cos());
        shape = shape.line(
            [c + (r - tick) * sx, c + (r - tick) * sy],
            [c + (r - 0.5) * sx, c + (r - 0.5) * sy],
            1.0,
            LineCap::Butt,
            t.c.grid_strong,
        );
    }
    // Front notch: a small wedge outside the ring pointing in.
    let (hw, h) = if geo.labels { (4.5, 6.5) } else { (3.5, 5.5) };
    shape.fill(vec![[c - hw, c - r - h], [c + hw, c - r - h], [c, c - r]], t.c.grid_strong)
}

/// The listener head and the front chevron inside the outer ring. See [`head_path`].
fn head_marks(geo: &RadarGeometry, t: &Theme) -> Shape {
    let (c, r) = (geo.center(), geo.radius());
    // Chevron "^" just inside the outer ring, pointing where the head faces.
    let (w, ht, th) = if geo.labels { (5.0, 4.5, 1.3) } else { (4.5, 4.0, 1.2) };
    let apex = c - r + 4.5;
    let chevron = thick_polyline(&[[c - w, apex + ht], [c, apex], [c + w, apex + ht]], th);
    head(Shape::new(), c, c, geo.head_radius, if geo.labels { 1.5 } else { 1.3 }, t).fill(chevron, t.c.grid_strong)
}

/// The listener seen from above, facing up, in the radar's stroke language: the skull drawn as
/// a ring (an ellipse a little longer than wide, `stroke` thick, `h` from the centre to the
/// crown), a small solid nose and two small ears standing just clear of it. Separate parts
/// never overlap, so the translucent ink never blends twice; the skull is one even-odd band of
/// true Béziers (Rune flattens them to 0.1 pt), so it stays smooth as the head turns.
fn head(shape: Shape, cx: f32, cy: f32, h: f32, stroke: f32, t: &Theme) -> Shape {
    let (rx, ry, half) = (h * 0.80, h * 0.95, stroke / 2.0);
    let skull = ellipse_path(ellipse_path(Path::new(), cx, cy, rx + half, ry + half), cx, cy, rx - half, ry - half);
    // Clear of the skull's outer edge by about a stroke.
    let gap = stroke * 0.8;
    let (nw, nh, base) = (h * 0.32, h * 0.36, cy - ry - half - gap);
    let nose = vec![[cx - nw, base], [cx, base - nh], [cx + nw, base]];
    let (erx, ery) = (stroke * 0.62, h * 0.30);
    let ex = rx + half + gap + erx;
    let ears = ellipse_path(ellipse_path(Path::new(), cx - ex, cy, erx, ery), cx + ex, cy, erx, ery);
    shape
        .fill_path_with(&skull, FillRule::EvenOdd, t.c.head)
        .fill(nose, t.c.head)
        .fill_path_with(&ears, FillRule::NonZero, t.c.head)
}

/// Ring labels (1 m, 2 m, 6 m) just inside each ring at 6 o'clock, behind the listener where
/// sources are rarest, and azimuth labels outside the ring at ±90° and 180°. Large radar only.
fn world_labels(geo: &RadarGeometry, t: &Theme) -> Vec<El> {
    let (c, r) = (geo.center(), geo.radius());
    let label = |key: &'static str, s: &str, x: f32, y: f32, w: f32, align: Align| {
        text(s).key(key).font(ty::TICK).color(t.c.ink_secondary).align(align).absolute(x, y).size(w, 11.0).a11y_hidden()
    };
    let mut out = Vec::new();
    for (key, metres, s) in [("lbl1", 1.0f32, "1\u{a0}m"), ("lbl2", 2.0, "2\u{a0}m"), ("lbl6", 6.0, "6\u{a0}m")] {
        let rho = geo.scale.rho(metres);
        out.push(label(key, s, c + 6.0, c + rho - 13.0, 24.0, Align::Start));
    }
    out.push(label("az90", &format::degrees(90.0), c + r + 5.0, c - 5.5, 26.0, Align::Start));
    out.push(label("az270", &format::degrees(-90.0), c - r - 5.0 - 26.0, c - 5.5, 26.0, Align::End));
    out.push(label("az180", "180°", c - 13.0, c + r + 4.0, 26.0, Align::Center));
    out
}

/// One source on its arm.
fn source_arm(i: usize, e: &Emitter, stage: &Soundstage, geo: &RadarGeometry, t: &Theme, active: bool, dense: bool) -> El {
    let (s, c) = (geo.size, geo.center());
    let rho = if e.far_field { geo.radius() } else { geo.scale.rho(stage.distance) };
    let d = if dense { geo.dot_dense } else { geo.dot };
    let marker = marker(e.layer, d, t, active).absolute(c - d / 2.0, c - rho - d / 2.0).frame_motion(t.motion.source);
    let mut arm = el()
        .key(ARM_KEYS[i.min(ARM_KEYS.len() - 1)])
        .absolute(0.0, 0.0)
        .size(s, s)
        .rotate_motion(t.motion.source)
        .rotate(e.azimuth.to_radians())
        .a11y_hidden()
        .child(marker);
    // L / R names on the large radar, turned back upright as the arm turns.
    if geo.labels && !dense && !e.label.is_empty() {
        let (lw, lh) = (14.0, 11.0);
        let y = c - rho - d / 2.0 - 4.0 - lh;
        arm = arm.child(
            text(e.label)
                .key("name")
                .font(ty::TICK)
                .color(t.c.ink_secondary)
                .align(Align::Center)
                .absolute(c - lw / 2.0, y)
                .size(lw, lh)
                .frame_motion(t.motion.source)
                .rotate_motion(t.motion.source)
                .rotate(-e.azimuth.to_radians()),
        );
    }
    arm
}

const ARM_KEYS: [&str; 12] = ["src0", "src1", "src2", "src3", "src4", "src5", "src6", "src7", "src8", "src9", "src10", "src11"];

/// A source marker. Live ear-level: a filled accent dot with a soft accent shadow. Live height
/// layer: an accent outline. Engine off: neutral outlines. Shape, not colour alone, tells them
/// apart.
pub(crate) fn marker(layer: Layer, d: f32, t: &Theme, active: bool) -> El {
    let dot = el().key("dot").size(d, d).radius(d / 2.0);
    match (active, layer) {
        (true, Layer::Ear) => dot.fill(t.c.accent).shadow(0.0, d * 1.25, t.c.accent_glow),
        (true, Layer::Height) => dot.border(1.5, t.c.accent),
        (false, Layer::Ear) => dot.border(1.25, t.c.ink_secondary),
        (false, Layer::Height) => dot.border(1.0, t.c.ink_tertiary),
    }
}

/// What the radar shows, in words.
fn describe(stage: &Soundstage, head_yaw: Option<f32>) -> String {
    let dist = stage.mode.uses_distance().then_some(stage.distance);
    let what = match stage.mode {
        SourceMode::MonoPoint => format!("Source {}", format::spoken_position(stage.azimuth, stage.elevation, dist)),
        SourceMode::StereoPoints => format!(
            "Stereo points, width ±{:.0}°, {}",
            stage.stereo_width,
            format::spoken_position(stage.azimuth, stage.elevation, dist)
        ),
        m => format!("{}, {}", m.label(), format::spoken_position(stage.azimuth, stage.elevation, dist)),
    };
    let head = match head_yaw {
        Some(y) => {
            let deg = y.to_degrees().round();
            if deg == 0.0 {
                "head facing front".to_owned()
            } else {
                format!("head turned {:.0}° {}", deg.abs(), if deg > 0.0 { "right" } else { "left" })
            }
        }
        None => "no head tracking".to_owned(),
    };
    format!("{what}; {head}")
}
