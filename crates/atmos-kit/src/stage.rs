//! The soundstage the instruments draw: the engine's source mode and source parameters, the
//! virtual sources each mode renders, and the radar's distance scale.
//!
//! Plain values only (no engine types): the composer copies them out of the bridge snapshot.

/// Parameter ranges (audit section (d); `Ranges.swift`).
pub mod range {
    pub const AZIMUTH: (f32, f32) = (-180.0, 180.0);
    pub const ELEVATION: (f32, f32) = (-90.0, 90.0);
    /// The engine clamps distance to `[0.35, distance_max]`; `distance_max` defaults to 6 m.
    pub const DISTANCE: (f32, f32) = (0.35, 6.0);
    /// Stereo width: ± spread of the two virtual speakers in Stereo Points.
    pub const STEREO_WIDTH: (f32, f32) = (0.0, 90.0);
    /// Meter scale.
    pub const METER_DB: (f32, f32) = (-60.0, 0.0);
}

/// The engine's `SourceRenderMode`, in its `u8` order (`set_config_rebuild(source_mode, u8)`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum SourceMode {
    /// Two mono point sources, L at `azimuth − width` and R at `azimuth + width` (the default).
    #[default]
    StereoPoints,
    /// One stereo far-field ambience bed; azimuth and elevation rotate it, distance is inert.
    StereoBed,
    /// One mono point source (downmix).
    MonoPoint,
    /// Eleven point sources at the 7.1.4 speaker angles (LFE unspatialized), rotated by azimuth
    /// and elevation, all at one distance.
    Surround714,
    /// One 12-channel far-field ambience bed; azimuth and elevation rotate it, distance is inert.
    SurroundBed714,
}

impl SourceMode {
    pub const ALL: [SourceMode; 5] =
        [SourceMode::StereoPoints, SourceMode::StereoBed, SourceMode::MonoPoint, SourceMode::Surround714, SourceMode::SurroundBed714];

    /// From the engine's `u8` (`dual_point_stereo` 0 … `surround_bed714` 4).
    pub fn from_u8(v: u8) -> Option<SourceMode> {
        SourceMode::ALL.get(v as usize).copied()
    }
    pub fn as_u8(self) -> u8 {
        self as u8
    }
    /// The engine's user-facing name.
    pub fn label(self) -> &'static str {
        match self {
            SourceMode::StereoPoints => "Stereo Points",
            SourceMode::StereoBed => "Stereo Bed",
            SourceMode::MonoPoint => "Mono Point",
            SourceMode::Surround714 => "Surround 7.1.4",
            SourceMode::SurroundBed714 => "Surround Bed 7.1.4",
        }
    }
    /// Ambience beds render far field: distance (and the distance model) are inert (audit L12).
    pub fn is_bed(self) -> bool {
        matches!(self, SourceMode::StereoBed | SourceMode::SurroundBed714)
    }
    pub fn uses_distance(self) -> bool {
        !self.is_bed()
    }
    /// The 12-channel 7.1.4 modes (they need the surround driver).
    pub fn is_surround(self) -> bool {
        matches!(self, SourceMode::Surround714 | SourceMode::SurroundBed714)
    }
}

/// Atmos 7.1.4 channel order, as `channel_peaks` and the engine's buses use it.
pub const ATMOS_714_LABELS: [&str; 12] = ["L", "R", "C", "LFE", "Ls", "Rs", "Rls", "Rrs", "Vhl", "Vhr", "Ltr", "Rtr"];
/// Canonical 7.1.4 speaker azimuths (degrees), in channel order (engine `kAtmos714Azimuth`).
pub const ATMOS_714_AZIMUTH: [f32; 12] = [-30.0, 30.0, 0.0, 0.0, -110.0, 110.0, -145.0, 145.0, -45.0, 45.0, -135.0, 135.0];
/// Canonical 7.1.4 speaker elevations (degrees), in channel order (engine `kAtmos714Elevation`).
pub const ATMOS_714_ELEVATION: [f32; 12] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 45.0, 45.0, 45.0, 45.0];
/// The LFE channel, rendered unspatialized (no position to draw).
pub const ATMOS_714_LFE: usize = 3;
/// Nominal half-width of a stereo ambience bed's L/R (the bed's own layout; not a parameter).
pub const STEREO_BED_HALF_WIDTH: f32 = 30.0;

/// The source parameters the engine renders (snapshot `azimuth`, `elevation`, `distance` (already
/// clamped to `distance_max`), `stereo_width`, and `source_mode`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Soundstage {
    pub mode: SourceMode,
    /// Degrees, −180…180, positive to the right (clockwise seen from above).
    pub azimuth: f32,
    /// Degrees, −90…90, positive up.
    pub elevation: f32,
    /// Metres, 0.35…6.
    pub distance: f32,
    /// Degrees, 0…90: ± spread of L/R in Stereo Points.
    pub stereo_width: f32,
}

impl Default for Soundstage {
    /// `SpatialConfig()` defaults: Stereo Points, front, ear level, 1 m, ±30°.
    fn default() -> Self {
        Soundstage { mode: SourceMode::StereoPoints, azimuth: 0.0, elevation: 0.0, distance: 1.0, stereo_width: 30.0 }
    }
}

/// Where a virtual source sits relative to the listener's ears.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Layer {
    /// Ear level (or wherever the stage's elevation puts the main layer).
    Ear,
    /// The 7.1.4 height layer (+45° above the main layer).
    Height,
}

/// One virtual source the engine renders, in world coordinates.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Emitter {
    /// Channel label ("L", "Vhl", …); empty for a mono point.
    pub label: &'static str,
    /// Degrees, wrapped to (−180, 180].
    pub azimuth: f32,
    /// Degrees, clamped to −90…90.
    pub elevation: f32,
    pub layer: Layer,
    /// A bed channel: far field, distance inert.
    pub far_field: bool,
}

/// Wraps degrees into (−180, 180].
pub fn wrap_degrees(deg: f32) -> f32 {
    if !deg.is_finite() {
        return 0.0;
    }
    let w = (deg + 180.0).rem_euclid(360.0) - 180.0;
    if w == -180.0 { 180.0 } else { w }
}

impl Soundstage {
    pub fn new(mode: SourceMode) -> Soundstage {
        Soundstage { mode, ..Soundstage::default() }
    }
    pub fn azimuth(mut self, deg: f32) -> Self {
        self.azimuth = deg;
        self
    }
    pub fn elevation(mut self, deg: f32) -> Self {
        self.elevation = deg;
        self
    }
    pub fn distance(mut self, metres: f32) -> Self {
        self.distance = metres;
        self
    }
    pub fn stereo_width(mut self, deg: f32) -> Self {
        self.stereo_width = deg;
        self
    }

    /// Values clamped to their ranges (non-finite values fall back to the defaults).
    pub fn clamped(self) -> Soundstage {
        let d = Soundstage::default();
        let fix = |v: f32, (lo, hi): (f32, f32), def: f32| if v.is_finite() { v.clamp(lo, hi) } else { def };
        Soundstage {
            mode: self.mode,
            azimuth: fix(self.azimuth, range::AZIMUTH, d.azimuth),
            elevation: fix(self.elevation, range::ELEVATION, d.elevation),
            distance: fix(self.distance, range::DISTANCE, d.distance),
            stereo_width: fix(self.stereo_width, range::STEREO_WIDTH, d.stereo_width),
        }
    }

    /// The virtual sources this mode renders, as the engine places them
    /// (`SpatialEngine.applySourceParams`).
    pub fn emitters(&self) -> Vec<Emitter> {
        let s = self.clamped();
        let el = |e: f32| e.clamp(range::ELEVATION.0, range::ELEVATION.1);
        let point = |label, az: f32, elev: f32, layer, far_field| Emitter {
            label,
            azimuth: wrap_degrees(az),
            elevation: el(elev),
            layer,
            far_field,
        };
        match s.mode {
            SourceMode::MonoPoint => vec![point("", s.azimuth, s.elevation, Layer::Ear, false)],
            SourceMode::StereoPoints => vec![
                point("L", s.azimuth - s.stereo_width, s.elevation, Layer::Ear, false),
                point("R", s.azimuth + s.stereo_width, s.elevation, Layer::Ear, false),
            ],
            SourceMode::StereoBed => vec![
                point("L", s.azimuth - STEREO_BED_HALF_WIDTH, s.elevation, Layer::Ear, true),
                point("R", s.azimuth + STEREO_BED_HALF_WIDTH, s.elevation, Layer::Ear, true),
            ],
            SourceMode::Surround714 | SourceMode::SurroundBed714 => {
                let far = s.mode == SourceMode::SurroundBed714;
                (0..12)
                    .filter(|&i| i != ATMOS_714_LFE)
                    .map(|i| {
                        let layer = if ATMOS_714_ELEVATION[i] > 0.0 { Layer::Height } else { Layer::Ear };
                        point(ATMOS_714_LABELS[i], ATMOS_714_AZIMUTH[i] + s.azimuth, ATMOS_714_ELEVATION[i] + s.elevation, layer, far)
                    })
                    .collect()
            }
        }
    }
}

/// The radar's distance scale (audit V1). A linear 0–6 m scale put the default 1 m source on
/// the head; this one keeps a head clearance `c` and spaces distance logarithmically:
///
/// - forward: `rho = c + (R − c) · ln(d / 0.35) / ln(6 / 0.35)`
/// - inverse (dragging): `d = 0.35 · (6 / 0.35)^((rho − c) / (R − c))`
///
/// so 0.35 m sits at the clearance radius, 6 m on the outer ring, and 1 m about 37% of the way
/// out, clear of the head at every size. The panel and the settings radar use the same scale.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RadarScale {
    /// Outer ring radius (6 m), points.
    pub radius: f32,
    /// Head clearance (0.35 m), points.
    pub clearance: f32,
}

impl RadarScale {
    const D_MIN: f32 = range::DISTANCE.0;
    const D_MAX: f32 = range::DISTANCE.1;

    /// Radius in points for `metres` (clamped to 0.35…6).
    pub fn rho(&self, metres: f32) -> f32 {
        let d = if metres.is_finite() { metres.clamp(Self::D_MIN, Self::D_MAX) } else { 1.0 };
        let t = (d / Self::D_MIN).ln() / (Self::D_MAX / Self::D_MIN).ln();
        self.clearance + (self.radius - self.clearance) * t
    }

    /// Metres for a radius in points (clamped to the clearance … outer ring).
    pub fn distance(&self, rho: f32) -> f32 {
        let span = (self.radius - self.clearance).max(1e-3);
        Self::at_fraction((rho - self.clearance) / span)
    }

    /// The scale position `0…1` of `metres` (0 at 0.35 m, 1 at 6 m).
    pub fn fraction(metres: f32) -> f32 {
        let d = metres.clamp(Self::D_MIN, Self::D_MAX);
        (d / Self::D_MIN).ln() / (Self::D_MAX / Self::D_MIN).ln()
    }

    /// Metres at scale position `t` (0…1).
    pub fn at_fraction(t: f32) -> f32 {
        let t = if t.is_finite() { t.clamp(0.0, 1.0) } else { 0.0 };
        // The ends exactly, not a rounding away from them.
        if t == 0.0 {
            Self::D_MIN
        } else if t == 1.0 {
            Self::D_MAX
        } else {
            (Self::D_MIN * (Self::D_MAX / Self::D_MIN).powf(t)).clamp(Self::D_MIN, Self::D_MAX)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scale_round_trips_and_clears_the_head() {
        let s = RadarScale { radius: 69.0, clearance: 18.0 };
        // The audit's example: 1 m at about 37 pt with R = 69, c = 18.
        assert!((s.rho(1.0) - 36.8).abs() < 0.5, "{}", s.rho(1.0));
        assert_eq!(s.rho(0.35), 18.0);
        assert_eq!(s.rho(6.0), 69.0);
        for d in [0.35, 0.5, 1.0, 1.7, 2.0, 4.5, 6.0] {
            assert!((s.distance(s.rho(d)) - d).abs() < 1e-3, "{d}");
        }
        assert_eq!(s.distance(0.0), 0.35);
        assert_eq!(s.distance(500.0), 6.0);
    }

    #[test]
    fn wrap_is_half_open() {
        assert_eq!(wrap_degrees(180.0), 180.0);
        assert_eq!(wrap_degrees(-180.0), 180.0);
        assert_eq!(wrap_degrees(190.0), -170.0);
        assert_eq!(wrap_degrees(-200.0), 160.0);
        assert_eq!(wrap_degrees(30.0), 30.0);
    }

    #[test]
    fn emitters_follow_the_engine() {
        let st = Soundstage::new(SourceMode::StereoPoints).azimuth(10.0).stereo_width(30.0);
        let e = st.emitters();
        assert_eq!(e.len(), 2);
        assert_eq!((e[0].label, e[0].azimuth), ("L", -20.0));
        assert_eq!((e[1].label, e[1].azimuth), ("R", 40.0));
        let s714 = Soundstage::new(SourceMode::Surround714).elevation(60.0).emitters();
        assert_eq!(s714.len(), 11);
        assert!(s714.iter().all(|e| e.label != "LFE"));
        assert!(s714.iter().filter(|e| e.layer == Layer::Height).all(|e| e.elevation == 90.0));
        assert!(Soundstage::new(SourceMode::SurroundBed714).emitters().iter().all(|e| e.far_field));
        assert_eq!(SourceMode::from_u8(4), Some(SourceMode::SurroundBed714));
        assert_eq!(SourceMode::from_u8(5), None);
    }
}
