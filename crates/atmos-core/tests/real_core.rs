//! The real libAtmosCore over the C ABI, end to end: create, snapshot, a state command, change
//! notification on the main queue, shutdown. `harness = false` so it runs on the process's
//! main thread (the C ABI's threading contract) and can drive the main run loop itself.
//!
//! It never powers the engine on: creating the core only enumerates audio devices and
//! registers CoreAudio listeners, and `set_field` changes state without touching the engine.

use std::cell::Cell;
use std::ffi::c_void;
use std::rc::Rc;
use std::time::{Duration, Instant};

use atmos_core::{ConfigField, Engine};

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFRunLoopDefaultMode: *const c_void;
    fn CFRunLoopRunInMode(mode: *const c_void, seconds: f64, return_after_source_handled: u8) -> i32;
}

/// Run the main run loop (which services the main dispatch queue) until `done` or `limit`.
fn pump_until(limit: Duration, done: impl Fn() -> bool) -> bool {
    let start = Instant::now();
    while !done() {
        if start.elapsed() > limit {
            return false;
        }
        // SAFETY: main thread; kCFRunLoopDefaultMode is a static CFStringRef.
        unsafe { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, 0) };
    }
    true
}

fn main() {
    if cfg!(atmos_core_mock_only) {
        println!("real_core: skipped (ATMOS_CORE_MOCK_ONLY build)");
        return;
    }
    let engine = Engine::real().expect("create the real core on the main thread");
    let notified = Rc::new(Cell::new(0u32));
    {
        let n = notified.clone();
        engine.set_on_change(move || n.set(n.get() + 1));
    }
    // Let anything the core did while starting up settle.
    pump_until(Duration::from_millis(200), || false);
    let original = engine.snapshot().config.distance_ref;

    // A state change, a snapshot read right after it (as a view does after a command), then a
    // second change in the same main-queue turn, before the coalesced notification ran.
    notified.set(0);
    engine.set_field(ConfigField::DistanceRef(2.0));
    let seen = engine.generation();
    assert_eq!(engine.snapshot().config.distance_ref, 2.0);
    engine.set_field(ConfigField::DistanceRef(3.0));

    assert!(pump_until(Duration::from_secs(2), || notified.get() > 0), "no change notification");
    assert_eq!(notified.get(), 1, "one coalesced notification per turn");
    // The notification must leave the UI able to see the second change: a generation equal to
    // the one it already drew would make it skip the redraw and keep showing 2.0.
    assert_ne!(engine.generation(), seen, "generation did not move after the notification");
    assert_eq!(engine.snapshot().config.distance_ref, 3.0, "stale snapshot after the notification");

    engine.set_field(ConfigField::DistanceRef(original));
    pump_until(Duration::from_millis(100), || false);
    assert_eq!(engine.snapshot().config.distance_ref, original);

    // Shutdown is idempotent and leaves the handle inert.
    engine.shutdown();
    engine.shutdown();
    engine.set_field(ConfigField::DistanceRef(2.5));
    assert_eq!(engine.snapshot().config.distance_ref, original, "commands after shutdown must be ignored");
    println!("real_core: ok");
}
