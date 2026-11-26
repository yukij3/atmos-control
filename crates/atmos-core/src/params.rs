//! Editable parameters: range, unit and mono readout format, shared by every surface so a
//! value set on one never looks clipped or rescaled on another. Defaults are not here: they
//! are the engine's (`Engine::defaults`, i.e. `SpatialConfig()`; audit L14).

use crate::types::Config;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Param {
    Azimuth,
    Elevation,
    Distance,
    Gain,
    StereoWidth,
    DistanceRef,
    DistanceMax,
    DistanceMaxAtten,
    ReverbBlend,
    GlobalReverbGain,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ParamSpec {
    pub min: f32,
    pub max: f32,
    /// Appended to the number, with its own leading space where one belongs ("°", " m").
    pub unit: &'static str,
    pub decimals: u8,
    /// Show "+" on positive values (and U+2212 "−" on negative ones, always).
    pub signed: bool,
}

impl Param {
    pub const ALL: &'static [Param] = &[
        Param::Azimuth, Param::Elevation, Param::Distance, Param::Gain, Param::StereoWidth,
        Param::DistanceRef, Param::DistanceMax, Param::DistanceMaxAtten, Param::ReverbBlend,
        Param::GlobalReverbGain,
    ];

    pub const fn spec(self) -> ParamSpec {
        const fn p(min: f32, max: f32, unit: &'static str, decimals: u8, signed: bool) -> ParamSpec {
            ParamSpec { min, max, unit, decimals, signed }
        }
        match self {
            Param::Azimuth => p(-180.0, 180.0, "°", 0, true),
            Param::Elevation => p(-90.0, 90.0, "°", 0, true),
            Param::Distance => p(0.35, 6.0, " m", 2, false),
            Param::Gain => p(-40.0, 12.0, " dB", 0, true),
            Param::StereoWidth => p(0.0, 90.0, "°", 0, false),
            Param::DistanceRef => p(0.1, 4.0, " m", 2, false),
            Param::DistanceMax => p(1.0, 20.0, " m", 1, false),
            Param::DistanceMaxAtten => p(0.0, 60.0, " dB", 0, false),
            Param::ReverbBlend => p(0.0, 100.0, " %", 0, false),
            Param::GlobalReverbGain => p(-40.0, 12.0, " dB", 0, true),
        }
    }

    /// This parameter's value in a config.
    pub fn get(self, c: &Config) -> f32 {
        match self {
            Param::Azimuth => c.azimuth,
            Param::Elevation => c.elevation,
            Param::Distance => c.distance,
            Param::Gain => c.gain,
            Param::StereoWidth => c.stereo_width,
            Param::DistanceRef => c.distance_ref,
            Param::DistanceMax => c.distance_max,
            Param::DistanceMaxAtten => c.distance_max_atten,
            Param::ReverbBlend => c.reverb_blend,
            Param::GlobalReverbGain => c.global_reverb_gain,
        }
    }

    /// The readout text, e.g. "+12°", "−3 dB", "1.00 m".
    pub fn format(self, v: f32) -> String { self.spec().format(v) }
}

impl ParamSpec {
    pub fn clamp(&self, v: f32) -> f32 { v.clamp(self.min, self.max) }

    /// Mono readout (audit L20): zero never carries a sign ("0°", not "+0°" or "-0°"), and
    /// negatives use U+2212 MINUS SIGN, which is as wide as "+" in SF Mono, so columns don't
    /// jitter.
    pub fn format(&self, v: f32) -> String {
        format!("{}{}", format_number(v, self.decimals, self.signed), self.unit)
    }
}

/// A number with `decimals` places; "−" (U+2212) for negatives; "+" for positives when
/// `signed`; no sign at all for a value that rounds to zero.
pub fn format_number(v: f32, decimals: u8, signed: bool) -> String {
    let digits = format!("{:.*}", decimals as usize, v.abs());
    let zero = digits.bytes().all(|b| b == b'0' || b == b'.');
    let sign = if zero { "" } else if v < 0.0 { "\u{2212}" } else if signed { "+" } else { "" };
    format!("{sign}{digits}")
}

/// Linear amplitude (0…1) to dBFS; `None` for silence (show "−∞").
pub fn linear_to_db(x: f32) -> Option<f32> { (x > 0.0).then(|| 20.0 * x.log10()) }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readouts_have_no_signed_zero_and_use_the_minus_sign() {
        assert_eq!(Param::Azimuth.format(0.0), "0°");
        assert_eq!(Param::Azimuth.format(-0.2), "0°");
        assert_eq!(Param::Azimuth.format(12.0), "+12°");
        assert_eq!(Param::Azimuth.format(-12.0), "\u{2212}12°");
        assert_eq!(Param::Distance.format(1.0), "1.00 m");
        assert_eq!(Param::Gain.format(-3.0), "\u{2212}3 dB");
        assert_eq!(Param::ReverbBlend.format(20.0), "20 %");
    }

    #[test]
    fn defaults_sit_inside_their_ranges() {
        let d = Config::DEFAULT;
        for p in Param::ALL {
            let s = p.spec();
            let v = p.get(&d);
            assert!(v >= s.min && v <= s.max, "{p:?} default {v} outside {}…{}", s.min, s.max);
        }
    }
}
