//! The real engine: libAtmosCore over the C ABI.

use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};

use atmos_core_sys as sys;

use crate::types::*;
use crate::EngineError;

/// The process's engine handle, for [`crate::shutdown_process_engine`] (a plain `fn()` hook).
static CORE: AtomicPtr<sys::AtmosCore> = AtomicPtr::new(std::ptr::null_mut());

pub(crate) struct Real {
    core: *mut sys::AtmosCore,
    raw: Box<sys::AtmosSnapshot>,
    defaults: Config,
    visible: Option<(bool, bool)>,
}

pub(crate) fn on_main_thread() -> bool {
    // Rust names the process's first thread "main"; on macOS that is the AppKit main thread.
    std::thread::current().name() == Some("main")
}

impl Real {
    pub(crate) fn create() -> Result<Real, EngineError> {
        if !sys::LINKED {
            return Err(EngineError::NotLinked);
        }
        if !on_main_thread() {
            return Err(EngineError::NotMainThread);
        }
        // SAFETY: static function, no preconditions.
        let abi = unsafe { sys::atmos_core_abi_version() };
        if abi != sys::ATMOS_CORE_ABI_VERSION {
            return Err(EngineError::AbiMismatch { library: abi, expected: sys::ATMOS_CORE_ABI_VERSION });
        }
        let mut raw_defaults = sys::AtmosConfig::default();
        // SAFETY: writes one AtmosConfig to a valid pointer.
        unsafe { sys::atmos_core_default_config(&mut raw_defaults) };
        // SAFETY: main thread (checked above).
        let core = unsafe { sys::atmos_core_create() };
        if core.is_null() {
            return Err(EngineError::CreateFailed);
        }
        CORE.store(core, Ordering::Release);
        Ok(Real { core, raw: sys::AtmosSnapshot::new(), defaults: Config::from_raw(&raw_defaults), visible: None })
    }

    pub(crate) fn defaults(&self) -> Config { self.defaults }

    pub(crate) fn generation(&self) -> u64 {
        // SAFETY: valid handle, main thread (Engine is !Send).
        unsafe { sys::atmos_core_generation(self.core) }
    }

    pub(crate) fn read(&mut self) -> Snapshot {
        self.raw.struct_size = size_of::<sys::AtmosSnapshot>() as u32;
        // SAFETY: valid handle; `raw` is a properly sized, aligned AtmosSnapshot.
        let ok = unsafe { sys::atmos_core_snapshot(self.core, &mut *self.raw) };
        debug_assert!(ok, "atmos_core_snapshot rejected the struct size");
        Snapshot::from_raw(&self.raw)
    }

    /// # Safety
    /// `context` must stay valid until replaced or unregistered; `callback` runs on the main
    /// thread.
    pub(crate) unsafe fn set_change_callback(&self, callback: sys::AtmosCallback, context: *mut c_void) {
        // SAFETY: forwarded contract.
        unsafe { sys::atmos_core_set_change_callback(self.core, callback, context) }
    }

    /// # Safety
    /// As [`set_change_callback`](Self::set_change_callback).
    pub(crate) unsafe fn set_terminate_callback(&self, callback: sys::AtmosCallback, context: *mut c_void) {
        // SAFETY: forwarded contract.
        unsafe { sys::atmos_core_set_terminate_callback(self.core, callback, context) }
    }

    pub(crate) fn set_visible(&mut self, panel: bool, settings: bool) {
        if self.visible == Some((panel, settings)) { return; }
        self.visible = Some((panel, settings));
        // SAFETY: valid handle, main thread.
        unsafe { sys::atmos_core_set_visible(self.core, panel, settings) }
    }

    pub(crate) fn call(&self, f: unsafe extern "C" fn(*mut sys::AtmosCore)) {
        // SAFETY: every command takes just the handle; valid handle, main thread.
        unsafe { f(self.core) }
    }

    pub(crate) fn set_capture_choice(&self, choice: CaptureChoice) {
        // SAFETY: valid handle, main thread.
        unsafe { sys::atmos_core_set_capture_choice(self.core, choice.raw()) }
    }

    pub(crate) fn select_output(&self, selection: OutputSelection) {
        let (follow, id) = match selection {
            OutputSelection::FollowDefault => (true, 0),
            OutputSelection::Device(id) => (false, id),
        };
        // SAFETY: valid handle, main thread.
        unsafe { sys::atmos_core_select_output(self.core, follow, id) }
    }

    pub(crate) fn set_field(&self, field: ConfigField) {
        let (f, v) = field.raw();
        // SAFETY: valid handle, main thread.
        unsafe { sys::atmos_core_set_field(self.core, f, v) }
    }

    pub(crate) fn set_source(&self, u: SourceUpdate) {
        let mut mask = 0;
        let mut v = |o: Option<f32>, bit: u32| o.map_or(0.0, |x| { mask |= bit; x });
        let (az, el, d, g, w) = (
            v(u.azimuth, sys::ATMOS_SOURCE_SET_AZIMUTH),
            v(u.elevation, sys::ATMOS_SOURCE_SET_ELEVATION),
            v(u.distance, sys::ATMOS_SOURCE_SET_DISTANCE),
            v(u.gain, sys::ATMOS_SOURCE_SET_GAIN),
            v(u.stereo_width, sys::ATMOS_SOURCE_SET_WIDTH),
        );
        // SAFETY: valid handle, main thread.
        unsafe { sys::atmos_core_set_source(self.core, mask, az, el, d, g, w) }
    }

    pub(crate) fn set_reverb_blend(&self, percent: f32) {
        // SAFETY: valid handle, main thread.
        unsafe { sys::atmos_core_set_reverb_blend(self.core, percent) }
    }
}

/// Run the engine's on-quit cleanup (synchronous; idempotent). Main thread only.
pub(crate) fn shutdown_core() {
    let core = CORE.load(Ordering::Acquire);
    if !core.is_null() && on_main_thread() {
        // SAFETY: the handle lives for the process; main thread.
        unsafe { sys::atmos_core_shutdown(core) }
    }
}
