//! Typed engine state: what the views read ([`Snapshot`]) and the values commands take.
//! Raw values are the C ABI's (`atmos_core.h`).

use atmos_core_sys as sys;

macro_rules! raw_enum {
    ($(#[$m:meta])* pub enum $name:ident { $($(#[$vm:meta])* $variant:ident = $raw:expr),+ $(,)? } default $def:ident) => {
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum $name { $($(#[$vm])* $variant),+ }
        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$variant),+];
            pub fn raw(self) -> u32 { match self { $($name::$variant => $raw),+ } }
            pub fn from_raw(raw: u32) -> Option<Self> { match raw { $(x if x == $raw => Some($name::$variant),)+ _ => None } }
            /// Lenient decode for values read from the engine: unknown raws fall back.
            pub(crate) fn decode(raw: u32) -> Self { Self::from_raw(raw).unwrap_or($name::$def) }
        }
        impl Default for $name { fn default() -> Self { $name::$def } }
    };
}

raw_enum! {
    /// What the user chooses to capture (Settings ▸ Audio capture).
    pub enum CaptureChoice {
        /// Process tap; headphones stay the system output, so personalized HRTF can engage.
        Personalized = sys::ATMOS_CAPTURE_PERSONALIZED,
        /// Loopback driver, 12-channel 7.1.4 (needs the 12-channel driver).
        Surround = sys::ATMOS_CAPTURE_SURROUND,
        /// Loopback driver, stereo (needs the driver).
        VirtualStereo = sys::ATMOS_CAPTURE_VIRTUAL_STEREO,
    } default Personalized
}

impl CaptureChoice {
    pub fn label(self) -> &'static str {
        match self {
            CaptureChoice::Personalized => "Personalized (headphones)",
            CaptureChoice::Surround => "Surround 7.1.4",
            CaptureChoice::VirtualStereo => "Stereo (virtual device)",
        }
    }
    /// The honest trade-off shown under the selected option.
    pub fn subtitle(self) -> &'static str {
        match self {
            CaptureChoice::Personalized => "Keeps your headphones as the system output so Apple personalized Spatial Audio can engage. No driver needed.",
            CaptureChoice::Surround => "True multichannel from Apple Music (set Music ▸ Dolby Atmos to Automatic). Personalized spatial profile unavailable in this mode.",
            CaptureChoice::VirtualStereo => "Routes all audio through the atmos-control virtual device. Works with any output, but rendering is generic (personalized HRTF can’t engage).",
        }
    }
    /// Whether this choice needs the loopback HAL driver (and which variant is present).
    pub fn available(self, atmos_present: bool, surround_driver_installed: bool) -> bool {
        match self {
            CaptureChoice::Personalized => true,
            CaptureChoice::VirtualStereo => atmos_present,
            CaptureChoice::Surround => surround_driver_installed,
        }
    }
}

raw_enum! {
    /// How the engine captures (derived from the capture choice).
    pub enum CaptureMode {
        Tap = sys::ATMOS_CAPTURE_MODE_TAP,
        Loopback = sys::ATMOS_CAPTURE_MODE_LOOPBACK,
    } default Tap
}

raw_enum! {
    pub enum OutputType {
        Headphones = sys::ATMOS_OUTPUT_HEADPHONES,
        BuiltInSpeakers = sys::ATMOS_OUTPUT_BUILT_IN,
        ExternalSpeakers = sys::ATMOS_OUTPUT_EXTERNAL,
    } default Headphones
}

impl OutputType {
    pub fn label(self) -> &'static str {
        match self {
            OutputType::Headphones => "Headphones",
            OutputType::BuiltInSpeakers => "Built-in Speakers",
            OutputType::ExternalSpeakers => "External Speakers",
        }
    }
    /// Compact form for narrow segmented controls.
    pub fn short_label(self) -> &'static str {
        match self {
            OutputType::Headphones => "Headphones",
            OutputType::BuiltInSpeakers => "Built-in",
            OutputType::ExternalSpeakers => "External",
        }
    }
}

raw_enum! {
    pub enum HrtfMode {
        Off = sys::ATMOS_HRTF_MODE_OFF,
        On = sys::ATMOS_HRTF_MODE_ON,
        Auto = sys::ATMOS_HRTF_MODE_AUTO,
    } default Auto
}

impl HrtfMode {
    pub fn label(self) -> &'static str {
        match self { HrtfMode::Off => "Off", HrtfMode::On => "On", HrtfMode::Auto => "Auto" }
    }
}

raw_enum! {
    pub enum Algorithm {
        Hrtf = sys::ATMOS_ALGORITHM_HRTF,
        HrtfHq = sys::ATMOS_ALGORITHM_HRTF_HQ,
        /// "Use Output Type": Apple's renderer; the only one personalized HRTF engages with.
        Automatic = sys::ATMOS_ALGORITHM_USE_OUTPUT_TYPE,
    } default Automatic
}

impl Algorithm {
    pub fn label(self) -> &'static str {
        match self { Algorithm::Hrtf => "HRTF", Algorithm::HrtfHq => "HRTF HQ", Algorithm::Automatic => "Automatic" }
    }
    /// The internal reverb renders only under HRTF / HRTF HQ (engine: `reverbActive`).
    pub fn supports_reverb(self) -> bool { self != Algorithm::Automatic }
}

raw_enum! {
    pub enum SourceMode {
        DualPointStereo = sys::ATMOS_SOURCE_DUAL_POINT_STEREO,
        AmbienceBedStereo = sys::ATMOS_SOURCE_AMBIENCE_BED_STEREO,
        PointSourceMono = sys::ATMOS_SOURCE_POINT_SOURCE_MONO,
        Surround714 = sys::ATMOS_SOURCE_SURROUND_714,
        SurroundBed714 = sys::ATMOS_SOURCE_SURROUND_BED_714,
    } default DualPointStereo
}

impl SourceMode {
    pub fn label(self) -> &'static str {
        match self {
            SourceMode::DualPointStereo => "Stereo Points",
            SourceMode::AmbienceBedStereo => "Stereo Bed",
            SourceMode::PointSourceMono => "Mono Point",
            SourceMode::Surround714 => "Surround 7.1.4",
            SourceMode::SurroundBed714 => "Surround Bed 7.1.4",
        }
    }
    pub fn is_surround(self) -> bool { matches!(self, SourceMode::Surround714 | SourceMode::SurroundBed714) }
    /// Bed modes set no rendering flags or distance params in the engine: inter-aural delay,
    /// the distance model and the source distance are inert there (audit L12).
    pub fn is_bed(self) -> bool { matches!(self, SourceMode::AmbienceBedStereo | SourceMode::SurroundBed714) }
    /// The modes a 2-channel capture (Personalized, Stereo) can render.
    pub const STEREO: &'static [SourceMode] = &[SourceMode::DualPointStereo, SourceMode::AmbienceBedStereo, SourceMode::PointSourceMono];
}

raw_enum! {
    pub enum AttenuationCurve {
        Power = sys::ATMOS_CURVE_POWER,
        Exponential = sys::ATMOS_CURVE_EXPONENTIAL,
        Inverse = sys::ATMOS_CURVE_INVERSE,
        Linear = sys::ATMOS_CURVE_LINEAR,
    } default Inverse
}

impl AttenuationCurve {
    pub fn label(self) -> &'static str {
        match self {
            AttenuationCurve::Power => "Power",
            AttenuationCurve::Exponential => "Exponential",
            AttenuationCurve::Inverse => "Inverse",
            AttenuationCurve::Linear => "Linear",
        }
    }
}

raw_enum! {
    pub enum RoomType {
        Small = sys::ATMOS_ROOM_SMALL,
        Medium = sys::ATMOS_ROOM_MEDIUM,
        Large = sys::ATMOS_ROOM_LARGE,
    } default Medium
}

impl RoomType {
    pub fn label(self) -> &'static str {
        match self { RoomType::Small => "Small", RoomType::Medium => "Medium", RoomType::Large => "Large" }
    }
}

raw_enum! {
    /// The power switch's text pair.
    pub enum EngineStatus {
        Off = sys::ATMOS_ENGINE_OFF,
        Starting = sys::ATMOS_ENGINE_STARTING,
        On = sys::ATMOS_ENGINE_ON,
        Stopping = sys::ATMOS_ENGINE_STOPPING,
    } default Off
}

raw_enum! {
    pub enum HrtfState {
        /// Engine off.
        Inactive = sys::ATMOS_HRTF_INACTIVE,
        /// Property 3116 = YES: the Apple personalized profile is active.
        Personalized = sys::ATMOS_HRTF_PERSONALIZED,
        /// See [`HrtfStatus::detail`] for the reason.
        Generic = sys::ATMOS_HRTF_GENERIC,
    } default Inactive
}

raw_enum! {
    pub enum HeadTrackState {
        /// Disabled in the config.
        Off = sys::ATMOS_HEAD_TRACK_OFF,
        /// Enabled, engine off.
        Inactive = sys::ATMOS_HEAD_TRACK_INACTIVE,
        /// Live head pose.
        Tracking = sys::ATMOS_HEAD_TRACK_TRACKING,
        /// Running, but no head-motion data (no AirPods, or none yet).
        Unavailable = sys::ATMOS_HEAD_TRACK_UNAVAILABLE,
    } default Off
}

/// The spatial renderer's configuration (`SpatialConfig`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Config {
    pub output_type: OutputType,
    pub hrtf_mode: HrtfMode,
    pub algorithm: Algorithm,
    pub source_mode: SourceMode,
    pub attenuation_curve: AttenuationCurve,
    pub reverb_room: RoomType,
    pub head_tracking: bool,
    pub interaural_delay: bool,
    pub distance_attenuation: bool,
    pub reverb_enabled: bool,
    /// Degrees, −180…180.
    pub azimuth: f32,
    /// Degrees, −90…90.
    pub elevation: f32,
    /// Metres, 0.35…6, never above `distance_max`.
    pub distance: f32,
    /// dB, −40…12.
    pub gain: f32,
    /// Degrees, 0…90 (Stereo Points only).
    pub stereo_width: f32,
    pub distance_ref: f32,
    pub distance_max: f32,
    pub distance_max_atten: f32,
    /// Percent, 0…100.
    pub reverb_blend: f32,
    pub global_reverb_gain: f32,
}

impl Config {
    /// `SpatialConfig()` as of this ABI version. The real engine's own defaults
    /// ([`crate::Engine::defaults`]) are authoritative; this copy serves the mock and is
    /// checked against the Swift library in the tests.
    pub const DEFAULT: Config = Config {
        output_type: OutputType::Headphones,
        hrtf_mode: HrtfMode::Auto,
        algorithm: Algorithm::Automatic,
        source_mode: SourceMode::DualPointStereo,
        attenuation_curve: AttenuationCurve::Inverse,
        reverb_room: RoomType::Medium,
        head_tracking: true,
        interaural_delay: true,
        distance_attenuation: false,
        reverb_enabled: true,
        azimuth: 0.0,
        elevation: 0.0,
        distance: 1.0,
        gain: 0.0,
        stereo_width: 30.0,
        distance_ref: 1.0,
        distance_max: 6.0,
        distance_max_atten: 40.0,
        reverb_blend: 20.0,
        global_reverb_gain: -3.0,
    };

    pub(crate) fn from_raw(c: &sys::AtmosConfig) -> Config {
        Config {
            output_type: OutputType::decode(c.output_type),
            hrtf_mode: HrtfMode::decode(c.hrtf_mode),
            algorithm: Algorithm::decode(c.algorithm),
            source_mode: SourceMode::decode(c.source_mode),
            attenuation_curve: AttenuationCurve::decode(c.attenuation_curve),
            reverb_room: RoomType::decode(c.reverb_room_type),
            head_tracking: c.head_tracking,
            interaural_delay: c.interaural_delay,
            distance_attenuation: c.distance_attenuation,
            reverb_enabled: c.reverb_enabled,
            azimuth: c.azimuth,
            elevation: c.elevation,
            distance: c.distance,
            gain: c.gain,
            stereo_width: c.stereo_width,
            distance_ref: c.distance_ref,
            distance_max: c.distance_max,
            distance_max_atten: c.distance_max_atten,
            reverb_blend: c.reverb_blend,
            global_reverb_gain: c.global_reverb_gain,
        }
    }

    /// Nothing for "Reset soundstage" to do (position, gain, stereo width).
    pub fn soundstage_is_default(&self, d: &Config) -> bool {
        self.azimuth == d.azimuth && self.elevation == d.elevation && self.distance == d.distance
            && self.gain == d.gain && self.stereo_width == d.stereo_width
    }

    /// Nothing for "Reset rendering" to do (algorithm, distance model, reverb).
    pub fn rendering_is_default(&self, d: &Config) -> bool {
        self.algorithm == d.algorithm && self.interaural_delay == d.interaural_delay
            && self.distance_attenuation == d.distance_attenuation && self.attenuation_curve == d.attenuation_curve
            && self.distance_ref == d.distance_ref && self.distance_max == d.distance_max
            && self.distance_max_atten == d.distance_max_atten && self.reverb_enabled == d.reverb_enabled
            && self.reverb_room == d.reverb_room && self.reverb_blend == d.reverb_blend
            && self.global_reverb_gain == d.global_reverb_gain
    }
}

impl Default for Config {
    fn default() -> Self { Config::DEFAULT }
}

/// A rebuild-class config change ([`crate::Engine::set_field`] then
/// [`crate::Engine::apply_config`]).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ConfigField {
    OutputType(OutputType),
    HrtfMode(HrtfMode),
    Algorithm(Algorithm),
    SourceMode(SourceMode),
    HeadTracking(bool),
    InterauralDelay(bool),
    DistanceAttenuation(bool),
    AttenuationCurve(AttenuationCurve),
    DistanceRef(f32),
    DistanceMax(f32),
    DistanceMaxAtten(f32),
    ReverbEnabled(bool),
    ReverbRoom(RoomType),
    GlobalReverbGain(f32),
}

impl ConfigField {
    pub(crate) fn raw(self) -> (u32, f64) {
        let b = |v: bool| if v { 1.0 } else { 0.0 };
        match self {
            ConfigField::OutputType(v) => (sys::ATMOS_FIELD_OUTPUT_TYPE, v.raw().into()),
            ConfigField::HrtfMode(v) => (sys::ATMOS_FIELD_HRTF_MODE, v.raw().into()),
            ConfigField::Algorithm(v) => (sys::ATMOS_FIELD_ALGORITHM, v.raw().into()),
            ConfigField::SourceMode(v) => (sys::ATMOS_FIELD_SOURCE_MODE, v.raw().into()),
            ConfigField::HeadTracking(v) => (sys::ATMOS_FIELD_HEAD_TRACKING, b(v)),
            ConfigField::InterauralDelay(v) => (sys::ATMOS_FIELD_INTERAURAL_DELAY, b(v)),
            ConfigField::DistanceAttenuation(v) => (sys::ATMOS_FIELD_DISTANCE_ATTENUATION, b(v)),
            ConfigField::AttenuationCurve(v) => (sys::ATMOS_FIELD_ATTENUATION_CURVE, v.raw().into()),
            ConfigField::DistanceRef(v) => (sys::ATMOS_FIELD_DISTANCE_REF, v.into()),
            ConfigField::DistanceMax(v) => (sys::ATMOS_FIELD_DISTANCE_MAX, v.into()),
            ConfigField::DistanceMaxAtten(v) => (sys::ATMOS_FIELD_DISTANCE_MAX_ATTEN, v.into()),
            ConfigField::ReverbEnabled(v) => (sys::ATMOS_FIELD_REVERB_ENABLED, b(v)),
            ConfigField::ReverbRoom(v) => (sys::ATMOS_FIELD_REVERB_ROOM_TYPE, v.raw().into()),
            ConfigField::GlobalReverbGain(v) => (sys::ATMOS_FIELD_GLOBAL_REVERB_GAIN, v.into()),
        }
    }

    /// Apply to a config (the mock's model of `atmos_core_set_field`).
    pub(crate) fn apply(self, c: &mut Config) {
        match self {
            ConfigField::OutputType(v) => c.output_type = v,
            ConfigField::HrtfMode(v) => c.hrtf_mode = v,
            ConfigField::Algorithm(v) => c.algorithm = v,
            ConfigField::SourceMode(v) => c.source_mode = v,
            ConfigField::HeadTracking(v) => c.head_tracking = v,
            ConfigField::InterauralDelay(v) => c.interaural_delay = v,
            ConfigField::DistanceAttenuation(v) => c.distance_attenuation = v,
            ConfigField::AttenuationCurve(v) => c.attenuation_curve = v,
            ConfigField::DistanceRef(v) => c.distance_ref = v,
            ConfigField::DistanceMax(v) => c.distance_max = v,
            ConfigField::DistanceMaxAtten(v) => c.distance_max_atten = v,
            ConfigField::ReverbEnabled(v) => c.reverb_enabled = v,
            ConfigField::ReverbRoom(v) => c.reverb_room = v,
            ConfigField::GlobalReverbGain(v) => c.global_reverb_gain = v,
        }
    }
}

/// Live source values to set ([`crate::Engine::set_source`]); `None` leaves one unchanged.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SourceUpdate {
    pub azimuth: Option<f32>,
    pub elevation: Option<f32>,
    pub distance: Option<f32>,
    pub gain: Option<f32>,
    pub stereo_width: Option<f32>,
}

/// Which real device the loopback modes render to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutputSelection {
    /// Follow the macOS default output.
    FollowDefault,
    /// A device from [`Snapshot::outputs`].
    Device(u32),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutputDevice {
    /// CoreAudio `AudioDeviceID`.
    pub id: u32,
    pub name: String,
    pub is_airpods: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct HrtfStatus {
    pub state: HrtfState,
    /// One word: "Inactive", "Personalized", "Generic".
    pub short: String,
    /// The reason sentence (tooltip / subtitle).
    pub detail: String,
    /// Draw with the accent.
    pub engaged: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct HeadTrackStatus {
    pub state: HeadTrackState,
    /// "Off", "Inactive", "Tracking", "Unavailable".
    pub text: String,
    pub active: bool,
}

/// Live readouts. They change only while a surface is visible
/// ([`crate::Engine::set_visible`]).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Telemetry {
    /// AUSpatialMixer property 3116.
    pub personalized_hrtf_engaged: bool,
    /// Linear 0…1, smoothed (fast attack, slow release).
    pub meter_l: f32,
    pub meter_r: f32,
    /// Linear 0…1, slowly decaying peak markers.
    pub peak_hold_l: f32,
    pub peak_hold_r: f32,
    /// Empty, or 12 values in Atmos 7.1.4 order (L R C LFE Ls Rs Rls Rrs Vhl Vhr Ltr Rtr) in
    /// the surround modes.
    pub channel_peaks: Vec<f32>,
    /// Radians; meaningful while `head_pose_live`.
    pub head_yaw: f64,
    pub head_pose_live: bool,
    /// Debug counters (show only with `ATMOS_DEBUG`).
    pub ring_fill: u64,
    pub total_captured: u64,
    pub total_played: u64,
}

/// Everything the views read, copied out of the engine in one go.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Snapshot {
    /// Changes whenever anything below may have changed.
    pub generation: u64,

    pub is_on: bool,
    /// A lifecycle operation (start, stop, rebuild) is in flight: disable the restart-class
    /// controls (power, capture choice, output device) — and only those (audit L2).
    pub busy: bool,
    /// The current capture choice can run (its driver is present).
    pub can_run: bool,
    /// Starting the tap failed on audio-capture consent.
    pub permission_needed: bool,
    pub engine_status: EngineStatus,
    /// "Off", "Starting…", "On", "Stopping…".
    pub engine_status_text: String,

    pub capture_choice: CaptureChoice,
    pub capture_mode: CaptureMode,
    /// The loopback HAL device exists.
    pub atmos_present: bool,
    /// ... with the full 12 channels (Surround).
    pub surround_driver_installed: bool,
    /// The device audio renders (or will render) to.
    pub output_name: String,
    /// Real output devices (loopback modes pick one of them).
    pub outputs: Vec<OutputDevice>,
    pub outputs_truncated: bool,
    /// `None` = follow the macOS default output.
    pub selected_output: Option<u32>,

    pub config: Config,
    pub telemetry: Telemetry,

    pub hrtf: HrtfStatus,
    pub head_track: HeadTrackStatus,
    /// Why the HRTF-mode picker is disabled; `None` = enabled.
    pub personalization_disabled_reason: Option<String>,
    /// Apple Music Dolby Atmos advice, while running.
    pub music_atmos_advisory: Option<String>,
    /// An error to show (never an info message).
    pub last_error: Option<String>,
    pub soundstage_is_default: bool,
    pub rendering_is_default: bool,
}

impl Snapshot {
    /// The power control is usable: the choice can run and nothing is in flight.
    pub fn can_toggle(&self) -> bool { !self.busy && (self.is_on || self.can_run) }
}

pub(crate) fn c_str(bytes: &[std::ffi::c_char]) -> String {
    // SAFETY: c_char and u8 have the same size and alignment.
    let bytes: &[u8] = unsafe { std::slice::from_raw_parts(bytes.as_ptr().cast(), bytes.len()) };
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

fn non_empty(s: String) -> Option<String> { if s.is_empty() { None } else { Some(s) } }

impl Snapshot {
    pub(crate) fn from_raw(s: &sys::AtmosSnapshot) -> Snapshot {
        let outputs = s.outputs[..(s.output_count as usize).min(sys::ATMOS_MAX_OUTPUTS)]
            .iter()
            .map(|d| OutputDevice { id: d.id, name: c_str(&d.name), is_airpods: d.is_airpods })
            .collect();
        let peaks = (s.channel_peak_count as usize).min(sys::ATMOS_MAX_CHANNELS);
        Snapshot {
            generation: s.generation,
            is_on: s.is_on,
            busy: s.busy,
            can_run: s.can_run,
            permission_needed: s.permission_needed,
            engine_status: EngineStatus::decode(s.engine_status),
            engine_status_text: c_str(&s.engine_status_text),
            capture_choice: CaptureChoice::decode(s.capture_choice),
            capture_mode: CaptureMode::decode(s.capture_mode),
            atmos_present: s.atmos_present,
            surround_driver_installed: s.surround_driver_installed,
            output_name: c_str(&s.output_name),
            outputs,
            outputs_truncated: s.outputs_truncated,
            selected_output: s.has_selected_output.then_some(s.selected_output_id),
            config: Config::from_raw(&s.config),
            telemetry: Telemetry {
                personalized_hrtf_engaged: s.personalized_hrtf_engaged,
                meter_l: s.meter_l,
                meter_r: s.meter_r,
                peak_hold_l: s.peak_hold_l,
                peak_hold_r: s.peak_hold_r,
                channel_peaks: s.channel_peaks[..peaks].to_vec(),
                head_yaw: s.head_yaw,
                head_pose_live: s.head_pose_live,
                ring_fill: s.ring_fill,
                total_captured: s.total_captured,
                total_played: s.total_played,
            },
            hrtf: HrtfStatus {
                state: HrtfState::decode(s.hrtf_status),
                short: c_str(&s.hrtf_short),
                detail: c_str(&s.hrtf_detail),
                engaged: s.hrtf_engaged,
            },
            head_track: HeadTrackStatus {
                state: HeadTrackState::decode(s.head_track_status),
                text: c_str(&s.head_track_status_text),
                active: s.head_track_active,
            },
            personalization_disabled_reason: non_empty(c_str(&s.personalization_disabled_reason)),
            music_atmos_advisory: non_empty(c_str(&s.music_atmos_advisory)),
            last_error: non_empty(c_str(&s.last_error)),
            soundstage_is_default: s.soundstage_is_default,
            rendering_is_default: s.rendering_is_default,
        }
    }
}
