//! atmos-kit: the custom-drawn instruments of atmos-control's Rune UI, and its design tokens.
//!
//! - [`theme`]: [`Theme`] (appearance, Reduce Motion, Increase Contrast, colours, motion), type
//!   roles ([`ty`]), spacing ([`space`]), SF Pro / SF Mono ([`theme::FAMILIES`]).
//! - [`Radar`]: the top-down soundstage, head tracking made visible, draggable on request.
//! - [`ElevationGauge`]: the slim elevation arc beside the radar.
//! - [`Meters`]: L/R or 12-channel level bars.
//! - [`Readout`]: `az +30° · el 0° · 1.0 m`, fixed width.
//!
//! Inputs are plain values ([`Soundstage`], linear levels, a yaw in radians); nothing here knows
//! the engine or the bridge. Builders end in `.build(&theme)` and return a Rune [`rune::El`].
//!
//! ```ignore
//! fn view(s: &App, cx: &mut Cx<App>) -> El {
//!     let t = Theme::from_cx(cx);
//!     let stage = Soundstage { mode, azimuth, elevation, distance, stereo_width };
//!     let yaw = s.head_pose_live.then_some(s.head_yaw as f32);
//!     row().gap(space::RADAR_GAUGE)
//!         .child(Radar::compact(stage).head_yaw(yaw).active(s.is_on).build(&t))
//!         .child(ElevationGauge::compact(stage).active(s.is_on).build(&t))
//!         .child(el().w(space::GROUP))
//!         .child(Meters::stereo(s.meter_l, s.meter_r, s.peak_hold_l, s.peak_hold_r).active(s.is_on).build(&t))
//! }
//! ```

#![forbid(unsafe_code)]

pub mod format;
pub mod gauge;
mod geom;
pub mod meter;
pub mod radar;
pub mod readout;
pub mod stage;
pub mod theme;

pub use gauge::{ElevationGauge, GaugeGeometry};
pub use meter::{MeterChannel, Meters, ScaleSide};
pub use radar::{EditPhase, Radar, RadarGeometry, SourceEdit};
pub use readout::Readout;
pub use stage::{Emitter, Layer, RadarScale, SourceMode, Soundstage};
pub use theme::{Motion, Palette, Theme, space, ty};
