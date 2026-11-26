//! Raw C ABI of libAtmosCore — hand-written mirror of
//! `Sources/AtmosCoreABI/include/atmos_core.h` (the single definition; change both together
//! and bump [`ATMOS_CORE_ABI_VERSION`]). The tests pin the struct layouts to the sizes and
//! offsets the header asserts at C compile time.
//!
//! Everything here is `unsafe` and main-thread-only (see the header's threading contract).
//! Use the safe `atmos-core` crate instead.
//!
//! Built with `ATMOS_CORE_MOCK_ONLY=1`, the functions are stubs that panic and [`LINKED`] is
//! false; callers must check it first.

#![allow(non_camel_case_types)]

use std::ffi::{c_char, c_void};

/// Whether libAtmosCore is linked (false in an `ATMOS_CORE_MOCK_ONLY` build).
pub const LINKED: bool = cfg!(not(atmos_core_mock_only));

pub const ATMOS_CORE_ABI_VERSION: u32 = 1;

pub const ATMOS_CAPTURE_PERSONALIZED: u32 = 0;
pub const ATMOS_CAPTURE_SURROUND: u32 = 1;
pub const ATMOS_CAPTURE_VIRTUAL_STEREO: u32 = 2;

pub const ATMOS_CAPTURE_MODE_TAP: u32 = 0;
pub const ATMOS_CAPTURE_MODE_LOOPBACK: u32 = 1;

pub const ATMOS_OUTPUT_HEADPHONES: u32 = 1;
pub const ATMOS_OUTPUT_BUILT_IN: u32 = 2;
pub const ATMOS_OUTPUT_EXTERNAL: u32 = 3;

pub const ATMOS_HRTF_MODE_OFF: u32 = 0;
pub const ATMOS_HRTF_MODE_ON: u32 = 1;
pub const ATMOS_HRTF_MODE_AUTO: u32 = 2;

pub const ATMOS_ALGORITHM_HRTF: u32 = 2;
pub const ATMOS_ALGORITHM_HRTF_HQ: u32 = 6;
pub const ATMOS_ALGORITHM_USE_OUTPUT_TYPE: u32 = 7;

pub const ATMOS_SOURCE_DUAL_POINT_STEREO: u32 = 0;
pub const ATMOS_SOURCE_AMBIENCE_BED_STEREO: u32 = 1;
pub const ATMOS_SOURCE_POINT_SOURCE_MONO: u32 = 2;
pub const ATMOS_SOURCE_SURROUND_714: u32 = 3;
pub const ATMOS_SOURCE_SURROUND_BED_714: u32 = 4;

pub const ATMOS_CURVE_POWER: u32 = 0;
pub const ATMOS_CURVE_EXPONENTIAL: u32 = 1;
pub const ATMOS_CURVE_INVERSE: u32 = 2;
pub const ATMOS_CURVE_LINEAR: u32 = 3;

pub const ATMOS_ROOM_SMALL: u32 = 0;
pub const ATMOS_ROOM_MEDIUM: u32 = 1;
pub const ATMOS_ROOM_LARGE: u32 = 2;

pub const ATMOS_ENGINE_OFF: u32 = 0;
pub const ATMOS_ENGINE_STARTING: u32 = 1;
pub const ATMOS_ENGINE_ON: u32 = 2;
pub const ATMOS_ENGINE_STOPPING: u32 = 3;

pub const ATMOS_HRTF_INACTIVE: u32 = 0;
pub const ATMOS_HRTF_PERSONALIZED: u32 = 1;
pub const ATMOS_HRTF_GENERIC: u32 = 2;

pub const ATMOS_HEAD_TRACK_OFF: u32 = 0;
pub const ATMOS_HEAD_TRACK_INACTIVE: u32 = 1;
pub const ATMOS_HEAD_TRACK_TRACKING: u32 = 2;
pub const ATMOS_HEAD_TRACK_UNAVAILABLE: u32 = 3;

pub const ATMOS_FIELD_OUTPUT_TYPE: u32 = 0;
pub const ATMOS_FIELD_HRTF_MODE: u32 = 1;
pub const ATMOS_FIELD_ALGORITHM: u32 = 2;
pub const ATMOS_FIELD_SOURCE_MODE: u32 = 3;
pub const ATMOS_FIELD_HEAD_TRACKING: u32 = 4;
pub const ATMOS_FIELD_INTERAURAL_DELAY: u32 = 5;
pub const ATMOS_FIELD_DISTANCE_ATTENUATION: u32 = 6;
pub const ATMOS_FIELD_ATTENUATION_CURVE: u32 = 7;
pub const ATMOS_FIELD_DISTANCE_REF: u32 = 8;
pub const ATMOS_FIELD_DISTANCE_MAX: u32 = 9;
pub const ATMOS_FIELD_DISTANCE_MAX_ATTEN: u32 = 10;
pub const ATMOS_FIELD_REVERB_ENABLED: u32 = 11;
pub const ATMOS_FIELD_REVERB_ROOM_TYPE: u32 = 12;
pub const ATMOS_FIELD_GLOBAL_REVERB_GAIN: u32 = 13;

pub const ATMOS_SOURCE_SET_AZIMUTH: u32 = 1 << 0;
pub const ATMOS_SOURCE_SET_ELEVATION: u32 = 1 << 1;
pub const ATMOS_SOURCE_SET_DISTANCE: u32 = 1 << 2;
pub const ATMOS_SOURCE_SET_GAIN: u32 = 1 << 3;
pub const ATMOS_SOURCE_SET_WIDTH: u32 = 1 << 4;

pub const ATMOS_NAME_CAP: usize = 128;
pub const ATMOS_STATUS_CAP: usize = 32;
pub const ATMOS_TEXT_CAP: usize = 256;
pub const ATMOS_ERROR_CAP: usize = 1024;
pub const ATMOS_MAX_OUTPUTS: usize = 32;
pub const ATMOS_MAX_CHANNELS: usize = 12;

pub const ATMOS_CORE_OUTPUT_DEVICE_SIZE: usize = 136;
pub const ATMOS_CORE_CONFIG_SIZE: usize = 68;
pub const ATMOS_CORE_SNAPSHOT_SIZE: usize = 6600;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct AtmosOutputDevice {
    pub id: u32,
    pub is_airpods: bool,
    pub name: [c_char; ATMOS_NAME_CAP],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct AtmosConfig {
    pub output_type: u32,
    pub hrtf_mode: u32,
    pub algorithm: u32,
    pub source_mode: u32,
    pub attenuation_curve: u32,
    pub reverb_room_type: u32,
    pub head_tracking: bool,
    pub interaural_delay: bool,
    pub distance_attenuation: bool,
    pub reverb_enabled: bool,
    pub azimuth: f32,
    pub elevation: f32,
    pub distance: f32,
    pub gain: f32,
    pub stereo_width: f32,
    pub distance_ref: f32,
    pub distance_max: f32,
    pub distance_max_atten: f32,
    pub reverb_blend: f32,
    pub global_reverb_gain: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct AtmosSnapshot {
    pub struct_size: u32,
    pub abi_version: u32,
    pub generation: u64,

    pub is_on: bool,
    pub busy: bool,
    pub can_run: bool,
    pub permission_needed: bool,
    pub engine_status: u32,

    pub capture_choice: u32,
    pub capture_mode: u32,
    pub atmos_present: bool,
    pub surround_driver_installed: bool,
    pub has_selected_output: bool,
    pub outputs_truncated: bool,
    pub selected_output_id: u32,
    pub output_count: u32,
    pub outputs: [AtmosOutputDevice; ATMOS_MAX_OUTPUTS],

    pub config: AtmosConfig,

    pub personalized_hrtf_engaged: bool,
    pub head_pose_live: bool,
    pub channel_peak_count: u32,
    pub meter_l: f32,
    pub meter_r: f32,
    pub peak_hold_l: f32,
    pub peak_hold_r: f32,
    pub channel_peaks: [f32; ATMOS_MAX_CHANNELS],
    pub head_yaw: f64,
    pub ring_fill: u64,
    pub total_captured: u64,
    pub total_played: u64,

    pub hrtf_status: u32,
    pub head_track_status: u32,
    pub hrtf_engaged: bool,
    pub head_track_active: bool,
    pub soundstage_is_default: bool,
    pub rendering_is_default: bool,

    pub engine_status_text: [c_char; ATMOS_STATUS_CAP],
    pub output_name: [c_char; ATMOS_NAME_CAP],
    pub hrtf_short: [c_char; ATMOS_STATUS_CAP],
    pub hrtf_detail: [c_char; ATMOS_TEXT_CAP],
    pub head_track_status_text: [c_char; ATMOS_STATUS_CAP],
    pub personalization_disabled_reason: [c_char; ATMOS_TEXT_CAP],
    pub music_atmos_advisory: [c_char; ATMOS_TEXT_CAP],
    pub last_error: [c_char; ATMOS_ERROR_CAP],
}

impl AtmosSnapshot {
    /// An all-zero snapshot with `struct_size` set, ready to pass to [`atmos_core_snapshot`].
    pub fn new() -> Box<Self> {
        // SAFETY: every field is an integer, float, bool or array of those; all-zero bytes are
        // a valid value for each (false for bool).
        let mut s: Box<Self> = unsafe { Box::new(std::mem::zeroed()) };
        s.struct_size = size_of::<Self>() as u32;
        s
    }
}

/// Opaque handle (`AtmosCore *`).
#[repr(C)]
pub struct AtmosCore {
    _private: [u8; 0],
}

pub type AtmosCallback = Option<unsafe extern "C" fn(context: *mut c_void)>;

macro_rules! abi {
    ($( $(#[$doc:meta])* pub fn $name:ident ( $($arg:ident : $ty:ty),* $(,)? ) $(-> $ret:ty)? ; )*) => {
        #[cfg(not(atmos_core_mock_only))]
        unsafe extern "C" {
            $( $(#[$doc])* pub fn $name($($arg: $ty),*) $(-> $ret)?; )*
        }
        #[cfg(atmos_core_mock_only)]
        mod stubs {
            #![allow(unused_variables, clippy::missing_safety_doc)]
            use super::*;
            $(
                pub unsafe extern "C" fn $name($($arg: $ty),*) $(-> $ret)? {
                    panic!(concat!(stringify!($name), ": libAtmosCore is not linked (ATMOS_CORE_MOCK_ONLY build)"))
                }
            )*
        }
        #[cfg(atmos_core_mock_only)]
        pub use stubs::*;
    };
}

abi! {
    pub fn atmos_core_abi_version() -> u32;
    pub fn atmos_core_default_config(out: *mut AtmosConfig);

    pub fn atmos_core_create() -> *mut AtmosCore;
    pub fn atmos_core_shutdown(core: *mut AtmosCore);

    pub fn atmos_core_set_change_callback(core: *mut AtmosCore, callback: AtmosCallback, context: *mut c_void);
    pub fn atmos_core_set_terminate_callback(core: *mut AtmosCore, callback: AtmosCallback, context: *mut c_void);

    pub fn atmos_core_generation(core: *mut AtmosCore) -> u64;
    pub fn atmos_core_snapshot(core: *mut AtmosCore, out: *mut AtmosSnapshot) -> bool;

    pub fn atmos_core_set_visible(core: *mut AtmosCore, panel: bool, settings: bool);

    pub fn atmos_core_power_on(core: *mut AtmosCore);
    pub fn atmos_core_power_off(core: *mut AtmosCore);
    pub fn atmos_core_toggle(core: *mut AtmosCore);
    pub fn atmos_core_retry_capture(core: *mut AtmosCore);
    pub fn atmos_core_open_privacy_settings(core: *mut AtmosCore);

    pub fn atmos_core_set_capture_choice(core: *mut AtmosCore, choice: u32);
    pub fn atmos_core_select_output(core: *mut AtmosCore, follow_default: bool, device_id: u32);
    pub fn atmos_core_refresh_devices(core: *mut AtmosCore);

    pub fn atmos_core_set_field(core: *mut AtmosCore, field: u32, value: f64);
    pub fn atmos_core_apply_config(core: *mut AtmosCore);

    pub fn atmos_core_set_source(core: *mut AtmosCore, mask: u32, azimuth: f32, elevation: f32,
                                 distance: f32, gain: f32, stereo_width: f32);
    pub fn atmos_core_set_reverb_blend(core: *mut AtmosCore, percent: f32);
    pub fn atmos_core_reset_soundstage(core: *mut AtmosCore);
    pub fn atmos_core_reset_rendering(core: *mut AtmosCore);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{align_of, offset_of, size_of};

    #[test]
    fn layout_matches_the_c_header() {
        assert_eq!(size_of::<AtmosOutputDevice>(), ATMOS_CORE_OUTPUT_DEVICE_SIZE);
        assert_eq!(size_of::<AtmosConfig>(), ATMOS_CORE_CONFIG_SIZE);
        assert_eq!(size_of::<AtmosSnapshot>(), ATMOS_CORE_SNAPSHOT_SIZE);
        assert_eq!(align_of::<AtmosSnapshot>(), 8);
        // The same pins as Sources/AtmosCoreABI/atmos_core_abi.c.
        assert_eq!(offset_of!(AtmosSnapshot, outputs), 44);
        assert_eq!(offset_of!(AtmosSnapshot, config), 4396);
        assert_eq!(offset_of!(AtmosSnapshot, head_yaw), 4536);
        assert_eq!(offset_of!(AtmosSnapshot, last_error), 5572);
    }

    #[cfg(not(atmos_core_mock_only))]
    #[test]
    fn the_linked_library_speaks_this_abi() {
        // Static functions: no main thread needed.
        assert_eq!(unsafe { atmos_core_abi_version() }, ATMOS_CORE_ABI_VERSION);
        let mut c = AtmosConfig::default();
        unsafe { atmos_core_default_config(&mut c) };
        assert_eq!(c.output_type, ATMOS_OUTPUT_HEADPHONES);
        assert_eq!(c.algorithm, ATMOS_ALGORITHM_USE_OUTPUT_TYPE);
        assert_eq!(c.distance, 1.0);
        assert_eq!(c.distance_ref, 1.0);
    }
}
