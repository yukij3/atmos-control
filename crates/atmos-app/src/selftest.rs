//! `ATMOS_SELFTEST=power-cycle`: a development probe for the assembled bundle, which can't be
//! driven by input without taking focus. It shows no window and injects no input: it logs the
//! menu-bar item and the engine snapshot, turns the engine on once through the same engine
//! calls the views make, logs the outcome (on, a permission request, an error) and a few
//! seconds of live telemetry, turns it off and logs that. Output goes to stderr, e.g.
//!
//! ```sh
//! open -g --env ATMOS_SELFTEST=power-cycle --stderr /tmp/atmos.log dist/atmos-control.app
//! ```
//!
//! Telemetry (meters, ring, captured/played frames) is only polled while a surface is on
//! screen, so the probe reports one as visible for its run, as an open panel would. It turns
//! head tracking off first: a visible surface would otherwise start CoreMotion, and a probe
//! must not raise the Motion permission prompt. Both are put back afterwards.
//!
//! The first start under a new code identity blocks while macOS shows the audio-capture
//! consent prompt (the HAL gives up after about 30 s), so the start wait outlasts that.

use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use atmos_core::ConfigField;
use rune::AppHandle;

use crate::panel::Panel;

/// Longer than the HAL's ~30 s wait on an unanswered audio-capture consent prompt.
const START_LIMIT: Duration = Duration::from_secs(40);
const STOP_LIMIT: Duration = Duration::from_secs(10);
/// A start still busy after this long is most likely waiting on the consent prompt.
const SLOW_START: Duration = Duration::from_secs(3);

pub fn start(panel: AppHandle<Panel>) {
    match std::env::var("ATMOS_SELFTEST").as_deref() {
        Ok("power-cycle") => {}
        Ok(other) => {
            eprintln!("atmos-control: selftest: unknown ATMOS_SELFTEST={other:?} (known: power-cycle)");
            return;
        }
        Err(_) => return,
    }
    let spawned = thread::Builder::new().name("atmos-selftest".into()).spawn(move || run(&panel));
    if let Err(err) = spawned {
        eprintln!("atmos-control: selftest: {err}");
    }
}

struct Probe {
    is_on: bool,
    busy: bool,
    stopped_for_permission: bool,
    head_tracking: bool,
    line: String,
}

/// Run `act` on the UI thread, then read the snapshot there.
fn probe(panel: &AppHandle<Panel>, act: impl FnOnce(&Panel) + Send + 'static) -> Option<Probe> {
    let (tx, rx) = mpsc::channel();
    panel.update_if(move |p, _| {
        act(p);
        let engine = &p.shell.engine;
        let s = engine.snapshot();
        let t = &s.telemetry;
        let line = format!(
            "gen {} | {} (on {}, busy {}) | capture {:?}/{:?} | output {:?} | hrtf {} | head {} | \
             permission_needed {} | meters {:.3}/{:.3} ring {} captured {} played {} | tray {:?} | error {:?}",
            engine.generation(), s.engine_status_text, s.is_on, s.busy,
            s.capture_choice, s.capture_mode, s.output_name, s.hrtf.short, s.head_track.text,
            s.permission_needed, t.meter_l, t.meter_r, t.ring_fill, t.total_captured, t.total_played,
            p.shell.tray_rect(), s.last_error,
        );
        let _ = tx.send(Probe {
            is_on: s.is_on,
            busy: s.busy,
            stopped_for_permission: s.permission_needed,
            head_tracking: s.config.head_tracking,
            line,
        });
        false
    });
    rx.recv_timeout(Duration::from_secs(5)).ok()
}

fn log(stage: &str, probe: Option<&Probe>) {
    match probe {
        Some(p) => eprintln!("atmos-control: selftest: {stage}: {}", p.line),
        None => eprintln!("atmos-control: selftest: {stage}: no answer from the UI thread in 5 s"),
    }
}

/// Poll until `done` holds or `limit` passes; log each change, and once if still busy after
/// [`SLOW_START`].
fn wait(panel: &AppHandle<Panel>, stage: &str, limit: Duration, done: fn(&Probe) -> bool) -> Option<Probe> {
    let started = Instant::now();
    let mut last = String::new();
    let mut flagged_slow = false;
    loop {
        let p = probe(panel, |_| {})?;
        let state = p.line.split(" | ").nth(1).unwrap_or_default().to_owned();
        if state != last {
            log(&format!("{stage} +{:.2}s", started.elapsed().as_secs_f64()), Some(&p));
            last = state;
        }
        if done(&p) {
            return Some(p);
        }
        if started.elapsed() > limit {
            log(&format!("{stage}: gave up after {} s", limit.as_secs()), Some(&p));
            return Some(p);
        }
        if p.busy && !flagged_slow && started.elapsed() > SLOW_START {
            flagged_slow = true;
            eprintln!(
                "atmos-control: selftest: {stage}: still busy after {} s; an audio-capture consent prompt \
                 may be waiting for an answer (the HAL gives up after ~30 s)",
                SLOW_START.as_secs()
            );
        }
        thread::sleep(Duration::from_millis(100));
    }
}

fn run(panel: &AppHandle<Panel>) {
    thread::sleep(Duration::from_millis(1500));
    let Some(launch) = probe(panel, |_| {}) else {
        log("launch", None);
        return;
    };
    log("launch", Some(&launch));

    // Observe telemetry without starting CoreMotion (see the module docs).
    let head_tracking = launch.head_tracking;
    probe(panel, |p| {
        if p.shell.engine.snapshot().config.head_tracking {
            p.shell.engine.set_and_apply(ConfigField::HeadTracking(false));
        }
        p.shell.engine.set_visible(true, false);
    });

    log("power_on", probe(panel, |p| p.shell.engine.power_on()).as_ref());
    if let Some(after_on) = wait(panel, "starting", START_LIMIT, |p| !p.busy) {
        if after_on.stopped_for_permission {
            eprintln!("atmos-control: selftest: the engine is waiting for audio-capture permission; not retrying");
        }
        if after_on.is_on {
            for second in 1..=3 {
                thread::sleep(Duration::from_secs(1));
                log(&format!("running {second} s"), probe(panel, |_| {}).as_ref());
            }
        }
    }

    log("power_off", probe(panel, |p| p.shell.engine.power_off()).as_ref());
    wait(panel, "stopping", STOP_LIMIT, |p| !p.busy && !p.is_on);

    probe(panel, move |p| {
        p.shell.report_visibility();
        if head_tracking {
            p.shell.engine.set_and_apply(ConfigField::HeadTracking(true));
        }
    });
    eprintln!("atmos-control: selftest: done");
}
