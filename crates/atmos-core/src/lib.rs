//! The engine API the Rune views use: one [`Engine`] per process, backed by the Swift engine
//! (libAtmosCore over the C ABI in `atmos-core-sys`) or by a [`mock`] with the same state
//! model.
//!
//! # Contract
//! - Main thread only. `Engine` is `!Send`; clone it (cheap, `Rc`) into each window's state.
//! - Reading: [`Engine::snapshot`] returns the latest [`Snapshot`], re-copied from the engine
//!   only when [`Engine::generation`] moved. Read it in `view`; compare generations to decide
//!   whether to redraw.
//! - Change notification: [`Engine::set_on_change`] registers a closure that runs on the main
//!   thread after the engine's state changed (real: on a later main-queue turn, coalesced;
//!   mock: right after the command or tick). Keep it to scheduling work (e.g.
//!   `AppHandle::update_if`), never call back into the `Engine` from it synchronously.
//! - Visibility: report which surfaces are on screen with [`Engine::set_visible`]; meters
//!   (15 Hz) and head pose (~25 Hz) only update while one is, and only then do they cost CPU.
//! - Mock clock: call [`Engine::tick`] from the window's `poll` with the frame clock (the
//!   real engine ignores it), and keep polling at ~30 Hz while [`Engine::wants_ticks`].
//! - Quit: [`shutdown_process_engine`] (or [`Engine::shutdown`]) must run before the process
//!   exits; it restores the system output in the loopback modes.

mod mock;
mod params;
mod real;
mod types;

use std::cell::{Cell, Ref, RefCell};
use std::ffi::c_void;
use std::fmt;
use std::rc::Rc;

pub use mock::{MockEngine, MockPreset};
pub use params::{Param, ParamSpec, format_number, linear_to_db};
pub use types::*;

/// Why the real engine couldn't be created.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EngineError {
    /// Built with `ATMOS_CORE_MOCK_ONLY`: libAtmosCore isn't linked.
    NotLinked,
    NotMainThread,
    AbiMismatch { library: u32, expected: u32 },
    CreateFailed,
}

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EngineError::NotLinked => f.write_str("built without libAtmosCore (ATMOS_CORE_MOCK_ONLY)"),
            EngineError::NotMainThread => f.write_str("the engine must be created on the main thread"),
            EngineError::AbiMismatch { library, expected } => write!(
                f, "libAtmosCore speaks ABI {library}, this build expects {expected}: rebuild both (App/build-app.sh)"),
            EngineError::CreateFailed => f.write_str("atmos_core_create returned no handle"),
        }
    }
}

impl std::error::Error for EngineError {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EngineKind {
    Real,
    Mock,
}

enum Backend {
    Real(real::Real),
    /// Boxed: the mock carries its whole snapshot, the real backend a pointer and a buffer.
    Mock(Box<MockEngine>),
}

type Hook = Box<dyn Fn()>;

struct Inner {
    backend: RefCell<Backend>,
    cache: RefCell<Snapshot>,
    cached_generation: Cell<Option<u64>>,
    /// Boxed twice so the C side holds a thin pointer to a stable `Box<dyn Fn()>`.
    on_change: RefCell<Option<Box<Hook>>>,
    on_terminate: RefCell<Option<Box<Hook>>>,
}

/// The engine handle. See the crate docs for the threading and notification contract.
#[derive(Clone)]
pub struct Engine {
    inner: Rc<Inner>,
}

unsafe extern "C" fn trampoline(context: *mut c_void) {
    // SAFETY: `context` is the address of a `Box<dyn Fn()>` owned by `Inner` and unregistered
    // before it is dropped (see `Engine::set_on_change`). Runs on the main thread. A panic here
    // aborts (extern "C" doesn't unwind).
    let hook = unsafe { &*(context as *const Hook) };
    hook();
}

impl Engine {
    fn with_backend(backend: Backend) -> Engine {
        Engine {
            inner: Rc::new(Inner {
                backend: RefCell::new(backend),
                cache: RefCell::new(Snapshot::default()),
                cached_generation: Cell::new(None),
                on_change: RefCell::new(None),
                on_terminate: RefCell::new(None),
            }),
        }
    }

    /// The Swift engine. Main thread only; one per process.
    pub fn real() -> Result<Engine, EngineError> {
        real::Real::create().map(|r| Engine::with_backend(Backend::Real(r)))
    }

    pub fn mock(preset: MockPreset) -> Engine {
        Engine::with_backend(Backend::Mock(Box::new(MockEngine::new(preset))))
    }

    /// Picks the backend for this process:
    /// - `ATMOS_ENGINE=mock|real` (or `--mock` / `--real` in `args`) decides;
    /// - else the mock when `prefer_mock` (headless renders), else the real engine;
    /// - the mock preset comes from `ATMOS_MOCK=<name>` (see [`MockPreset::from_name`]).
    ///
    /// Falls back to the mock (with the reason as the second value) when the real engine
    /// can't be created.
    pub fn select(args: &[String], prefer_mock: bool) -> (Engine, Option<String>) {
        let env = std::env::var("ATMOS_ENGINE").unwrap_or_default();
        let want_mock = if env == "mock" || args.iter().any(|a| a == "--mock") {
            true
        } else if env == "real" || args.iter().any(|a| a == "--real") {
            false
        } else {
            prefer_mock
        };
        let preset_name = std::env::var("ATMOS_MOCK").unwrap_or_default();
        let preset = MockPreset::from_name(&preset_name).unwrap_or_default();
        let mut note = (!preset_name.is_empty() && MockPreset::from_name(&preset_name).is_none()).then(|| {
            let names: Vec<_> = MockPreset::ALL.iter().map(|p| p.name()).collect();
            format!("unknown ATMOS_MOCK={preset_name:?} (presets: {}); using \"playing\"", names.join(", "))
        });
        if want_mock {
            return (Engine::mock(preset), note);
        }
        match Engine::real() {
            Ok(e) => (e, note),
            Err(err) => {
                note = Some(format!("real engine unavailable ({err}); using the mock engine"));
                (Engine::mock(preset), note)
            }
        }
    }

    pub fn kind(&self) -> EngineKind {
        match &*self.inner.backend.borrow() {
            Backend::Real(_) => EngineKind::Real,
            Backend::Mock(_) => EngineKind::Mock,
        }
    }

    /// Changes whenever the snapshot may have changed.
    pub fn generation(&self) -> u64 {
        match &*self.inner.backend.borrow() {
            Backend::Real(r) => r.generation(),
            Backend::Mock(m) => m.generation(),
        }
    }

    /// The latest state. Cheap when nothing changed; a copy-out from the engine otherwise.
    /// Don't hold the `Ref` across a call that changes the engine.
    pub fn snapshot(&self) -> Ref<'_, Snapshot> {
        let generation = self.generation();
        if self.inner.cached_generation.get() != Some(generation)
            && let (Ok(mut cache), Ok(mut backend)) = (self.inner.cache.try_borrow_mut(), self.inner.backend.try_borrow_mut())
        {
            *cache = match &mut *backend {
                Backend::Real(r) => r.read(),
                Backend::Mock(m) => m.snapshot().clone(),
            };
            self.inner.cached_generation.set(Some(generation));
        }
        self.inner.cache.borrow()
    }

    /// The engine's defaults (`SpatialConfig()`): what both Resets restore.
    pub fn defaults(&self) -> Config {
        match &*self.inner.backend.borrow() {
            Backend::Real(r) => r.defaults(),
            Backend::Mock(m) => m.defaults(),
        }
    }

    /// Register the change hook (replaces the previous one). See the crate docs.
    pub fn set_on_change(&self, hook: impl Fn() + 'static) {
        let boxed: Box<Hook> = Box::new(Box::new(hook));
        let ptr = &*boxed as *const Hook as *mut c_void;
        if let Backend::Real(r) = &*self.inner.backend.borrow() {
            // SAFETY: `boxed` is stored in `Inner` below and outlives the registration: it is
            // replaced only by a later registration, and `Drop` unregisters.
            unsafe { r.set_change_callback(Some(trampoline), ptr) };
        }
        *self.inner.on_change.borrow_mut() = Some(boxed);
    }

    /// Register a hook for SIGTERM / SIGINT / SIGHUP (real engine only): quit through the
    /// app's normal path so [`shutdown_process_engine`] runs.
    pub fn set_on_terminate(&self, hook: impl Fn() + 'static) {
        let boxed: Box<Hook> = Box::new(Box::new(hook));
        let ptr = &*boxed as *const Hook as *mut c_void;
        if let Backend::Real(r) = &*self.inner.backend.borrow() {
            // SAFETY: as in `set_on_change`.
            unsafe { r.set_terminate_callback(Some(trampoline), ptr) };
        }
        *self.inner.on_terminate.borrow_mut() = Some(boxed);
    }

    fn notify_mock(&self) {
        if let Ok(hook) = self.inner.on_change.try_borrow()
            && let Some(hook) = hook.as_ref()
        {
            hook();
        }
    }

    /// Run a command: real → the C function; mock → the mock's method, then the change hook.
    fn command(&self, real: impl FnOnce(&mut real::Real), mock: impl FnOnce(&mut MockEngine)) {
        let is_mock = {
            let mut backend = self.inner.backend.borrow_mut();
            match &mut *backend {
                Backend::Real(r) => { real(r); false }
                Backend::Mock(m) => { mock(m); true }
            }
        };
        if is_mock { self.notify_mock(); }
    }

    /// Advance the mock's clock (seconds; any monotonic origin). No-op for the real engine.
    /// Returns whether the snapshot changed.
    pub fn tick(&self, now: f64) -> bool {
        let changed = match &mut *self.inner.backend.borrow_mut() {
            Backend::Real(_) => false,
            Backend::Mock(m) => m.tick(now),
        };
        if changed { self.notify_mock(); }
        changed
    }

    /// Whether the mock wants [`tick`](Self::tick) calls at ~30 Hz now.
    pub fn wants_ticks(&self) -> bool {
        match &*self.inner.backend.borrow() {
            Backend::Real(_) => false,
            Backend::Mock(m) => m.wants_ticks(),
        }
    }

    /// Mock only: reset to a preset (Rune scenes use this). No-op for the real engine.
    pub fn mock_preset(&self, preset: MockPreset) {
        self.command(|_| {}, |m| m.apply_preset(preset));
    }

    /// Which surfaces are on screen (shown and not fully covered). Gates meter polling and
    /// head motion. Cheap to call repeatedly; only changes reach the engine.
    pub fn set_visible(&self, panel: bool, settings: bool) {
        self.command(|r| r.set_visible(panel, settings), |m| m.set_visible(panel, settings));
    }

    pub fn power_on(&self) { self.command(|r| r.call(atmos_core_sys::atmos_core_power_on), MockEngine::power_on); }
    pub fn power_off(&self) { self.command(|r| r.call(atmos_core_sys::atmos_core_power_off), MockEngine::power_off); }
    pub fn toggle(&self) { self.command(|r| r.call(atmos_core_sys::atmos_core_toggle), MockEngine::toggle); }
    /// After a permission failure: try the tap again (doesn't change routing).
    pub fn retry_capture(&self) { self.command(|r| r.call(atmos_core_sys::atmos_core_retry_capture), MockEngine::retry_capture); }
    /// System Settings ▸ Privacy & Security ▸ audio capture.
    pub fn open_privacy_settings(&self) { self.command(|r| r.call(atmos_core_sys::atmos_core_open_privacy_settings), |_| {}); }
    pub fn refresh_devices(&self) { self.command(|r| r.call(atmos_core_sys::atmos_core_refresh_devices), |_| {}); }

    /// Ignored while busy; restarts the engine if it runs.
    pub fn set_capture_choice(&self, choice: CaptureChoice) {
        self.command(|r| r.set_capture_choice(choice), |m| m.set_capture_choice(choice));
    }
    /// Loopback modes only.
    pub fn select_output(&self, selection: OutputSelection) {
        self.command(|r| r.select_output(selection), |m| m.select_output(selection));
    }
    /// Update a rebuild-class field in the state (shown at once) without touching the engine;
    /// [`apply_config`](Self::apply_config) applies it. During a slider drag: `set_field` per
    /// step, `apply_config` on release.
    pub fn set_field(&self, field: ConfigField) {
        self.command(|r| r.set_field(field), |m| m.set_field(field));
    }
    pub fn apply_config(&self) {
        self.command(|r| r.call(atmos_core_sys::atmos_core_apply_config), MockEngine::apply_config);
    }
    /// `set_field` then `apply_config`, for pickers and toggles.
    pub fn set_and_apply(&self, field: ConfigField) {
        self.set_field(field);
        self.apply_config();
    }
    /// Live, no rebuild.
    pub fn set_source(&self, update: SourceUpdate) {
        self.command(|r| r.set_source(update), |m| m.set_source(update));
    }
    /// Live, no rebuild (inert under the Automatic algorithm).
    pub fn set_reverb_blend(&self, percent: f32) {
        self.command(|r| r.set_reverb_blend(percent), |m| m.set_reverb_blend(percent));
    }
    /// Position, gain, stereo width.
    pub fn reset_soundstage(&self) {
        self.command(|r| r.call(atmos_core_sys::atmos_core_reset_soundstage), MockEngine::reset_soundstage);
    }
    /// Algorithm, distance model, reverb.
    pub fn reset_rendering(&self) {
        self.command(|r| r.call(atmos_core_sys::atmos_core_reset_rendering), MockEngine::reset_rendering);
    }

    /// The on-quit cleanup (synchronous, idempotent). Same as [`shutdown_process_engine`].
    pub fn shutdown(&self) {
        if self.kind() == EngineKind::Real { real::shutdown_core(); }
    }
}

impl Drop for Inner {
    fn drop(&mut self) {
        if let Backend::Real(r) = &*self.backend.borrow() {
            // SAFETY: unregister before the hooks are freed.
            unsafe {
                r.set_change_callback(None, std::ptr::null_mut());
                r.set_terminate_callback(None, std::ptr::null_mut());
            }
        }
    }
}

/// Run the real engine's on-quit cleanup, if this process created one: stop the engine,
/// destroy the process tap, restore the system default output in the loopback modes.
/// Synchronous and idempotent; main thread only (a no-op elsewhere). A plain `fn()` for
/// `rune::fast_exit`.
pub fn shutdown_process_engine() {
    real::shutdown_core();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_over_the_mock_notifies_and_caches() {
        let e = Engine::mock(MockPreset::Off);
        let hits = Rc::new(Cell::new(0));
        let h = hits.clone();
        e.set_on_change(move || h.set(h.get() + 1));
        let g0 = e.snapshot().generation;
        e.tick(0.0);
        e.power_on();
        assert_eq!(hits.get(), 1);
        assert!(e.snapshot().busy);
        assert_ne!(e.snapshot().generation, g0);
        assert!(e.wants_ticks());
        e.tick(1.0);
        assert!(e.snapshot().is_on);
        assert_eq!(e.snapshot().engine_status_text, "On");
    }

    #[cfg(not(atmos_core_mock_only))]
    #[test]
    fn mock_defaults_match_the_swift_engine() {
        let mut raw = atmos_core_sys::AtmosConfig::default();
        // SAFETY: static function writing one AtmosConfig.
        unsafe { atmos_core_sys::atmos_core_default_config(&mut raw) };
        assert_eq!(Config::from_raw(&raw), Config::DEFAULT, "update Config::DEFAULT to SpatialConfig()");
    }
}
