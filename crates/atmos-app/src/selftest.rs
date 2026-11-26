//! `ATMOS_SELFTEST=power-cycle`: a development probe for the assembled bundle, which can't be
//! driven by input without taking focus. It shows no window and injects no input: it logs the
//! menu-bar item and the engine snapshot, turns the engine on once through the same engine
//! calls the views make, logs the outcome (on, a permission request, an error), turns it off
//! and logs that. Output goes to stderr, e.g.
//!
//! ```sh
//! open -g --env ATMOS_SELFTEST=power-cycle --stderr /tmp/atmos.log dist/atmos-control.app
//! ```

use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use rune::AppHandle;

use crate::panel::Panel;

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
    line: String,
}

/// Run `act` on the UI thread, then read the snapshot there.
fn probe(panel: &AppHandle<Panel>, act: fn(&Panel)) -> Option<Probe> {
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

/// Poll until `done` holds or `limit` passes; log each change.
fn wait(panel: &AppHandle<Panel>, stage: &str, limit: Duration, done: fn(&Probe) -> bool) -> Option<Probe> {
    let started = Instant::now();
    let mut last = String::new();
    loop {
        let p = probe(panel, |_| {})?;
        let state = p.line.split(" | ").nth(1).unwrap_or_default().to_owned();
        if state != last {
            log(&format!("{stage} +{:.2}s", started.elapsed().as_secs_f64()), Some(&p));
            last = state;
        }
        if done(&p) || started.elapsed() > limit {
            return Some(p);
        }
        thread::sleep(Duration::from_millis(100));
    }
}

fn run(panel: &AppHandle<Panel>) {
    thread::sleep(Duration::from_millis(1500));
    log("launch", probe(panel, |_| {}).as_ref());

    log("power_on", probe(panel, |p| p.shell.engine.power_on()).as_ref());
    let Some(after_on) = wait(panel, "starting", Duration::from_secs(10), |p| !p.busy) else { return };
    if after_on.stopped_for_permission {
        eprintln!("atmos-control: selftest: the engine is waiting for audio-capture permission; not retrying");
    }
    if after_on.is_on {
        thread::sleep(Duration::from_secs(2));
        log("running 2 s", probe(panel, |_| {}).as_ref());
    }

    log("power_off", probe(panel, |p| p.shell.engine.power_off()).as_ref());
    wait(panel, "stopping", Duration::from_secs(10), |p| !p.busy && !p.is_on);
    eprintln!("atmos-control: selftest: done");
}
