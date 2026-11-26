//! atmos-control: a menu-bar (accessory) app. The Rune UI owns the main thread and the
//! NSApplication run loop; the Swift engine (libAtmosCore) runs in-process behind the C ABI
//! (`atmos-core`). One process, one bundle, one TCC identity.
//!
//! Windows (both retained, created on first show):
//! - `panel`: borderless, nonactivating Liquid Glass panel under the menu-bar item, as tall as
//!   its content; primary click on the item toggles it; Esc or clicking elsewhere hides it.
//! - `settings`: an ordinary titled window, one instance (menu-bar menu "Settings…", the
//!   panel, ⌘,).
//!
//! Engine: the real one by default; the mock with `--mock` / `ATMOS_ENGINE=mock`, and by
//! default in headless tooling runs (`--snap`, `--tree`, ...). `ATMOS_MOCK=<preset>` or
//! `--scene <preset>` picks the mock's state (playing, off, starting, permission, error,
//! speakers, surround; the panel adds `waiting`, a start held by the audio-capture prompt).
//! Headless renders show a MOCK badge for the mock engine; `ATMOS_DOCS_SHOT=1` leaves it out
//! (README screenshots). `ATMOS_DEBUG=1` logs where the panel opens. Examples:
//!
//! ```sh
//! target/release/atmos-control --snap panel.png --scale 2 --at 1.5
//! target/release/atmos-control --window settings --scene speakers --snap settings.png
//! ```
//!
//! `ATMOS_SELFTEST=power-cycle` runs one logged engine on/off without any window (`selftest`).
//! `ATMOS_OPEN_PANEL=1` opens the panel once at launch, a window check that needs no click:
//!
//! ```sh
//! ATMOS_ENGINE=mock ATMOS_DEBUG=1 ATMOS_OPEN_PANEL=1 target/release/atmos-control
//! ```

mod glyph;
mod panel;
mod selftest;
mod settings;
mod shell;
mod ui;

use atmos_core::Engine;
use rune::{App, AppSpec, MacWindowOptions, RunOptions, WindowOptions, WindowSpec};

use panel::Panel;
use settings::Settings;
use shell::{PANEL_SIZE, PANEL_WIDTH, Shell};

/// The panel's fixed width and the bounds its content height moves within.
const PANEL_MIN: (f32, f32) = (PANEL_WIDTH, 120.0);
const PANEL_MAX: (f32, f32) = (PANEL_WIDTH, 4000.0);

/// NSStatusWindowLevel: above other apps' windows, as menu-bar popovers sit.
const PANEL_LEVEL: isize = 25;
/// NSWindowCollectionBehavior: CanJoinAllSpaces | Transient | IgnoresCycle | FullScreenAuxiliary.
const PANEL_COLLECTION: usize = (1 << 0) | (1 << 3) | (1 << 6) | (1 << 8);

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // A headless tooling run (no windows, no status item), decided exactly as Rune's `run`
    // decides it: a hand-kept flag list drifted (`--duration` alone ran headless with the real
    // engine and a tray icon).
    let headless = rune::is_headless();

    // The last step of every normal quit (⌘Q, menu Quit, logout, a SIGTERM routed below):
    // stop the engine, destroy the tap, restore the default output. Rune ends the process
    // right after it, so nothing after `run` would run.
    rune::fast_exit(atmos_core::shutdown_process_engine);
    // A panic in a UI callback ends the event loop without the quit hooks (`fast_exit` doesn't
    // run); Rune re-raises it out of `run_windows_with`. Run the cleanup while it unwinds, or a
    // loopback mode leaves the system output on the virtual device (all audio silent).
    let _cleanup_on_panic = CleanupOnPanic;

    rune::run_windows_with(RunOptions { accessory: true }, move |_displays| {
        let (engine, note) = Engine::select(&args, headless);
        if let Some(note) = note {
            eprintln!("atmos-control: {note}");
        }

        // SF Pro and SF Mono in both windows' sans and mono slots, so rune-kit controls set in
        // the system font like atmos-kit's text does.
        let panel_app = App::new(AppSpec::<Panel> {
            scenes: panel::SCENES,
            poll: Some(panel::poll),
            on_key: Some(panel::on_key),
            min_size: Some(PANEL_MIN),
            families: atmos_kit::theme::FAMILIES,
            ..AppSpec::new("atmos-control", PANEL_SIZE, || unreachable!("App::init builds the state"), panel::view)
        })
        .windowless()
        // The panel is exactly as tall as its content (audit L21); the content caps itself at
        // the room below the menu bar and scrolls past that.
        .fit_content_height()
        .on_focus(panel::on_focus)
        .on_visibility(panel::on_visibility);

        let settings_app = App::new(AppSpec::<Settings> {
            scenes: settings::SCENES,
            poll: Some(settings::poll),
            on_key: Some(settings::on_key),
            min_size: Some(settings::MIN_SIZE),
            families: atmos_kit::theme::FAMILIES,
            ..AppSpec::new("atmos-control Settings", settings::SIZE, || unreachable!("App::init builds the state"), settings::view)
        })
        .windowless()
        .on_close(settings::on_close)
        .on_visibility(settings::on_visibility);

        let (panel_handle, settings_handle) = (panel_app.handle(), settings_app.handle());
        let shell = Shell::new(engine, headless, panel_handle.clone(), settings_handle.clone());

        // Engine → UI: each window catches up on its next turn (also while hidden: the panel's
        // `sync` keeps the menu-bar glyph current). Never re-enters the engine synchronously.
        {
            let (p, s) = (panel_handle.clone(), settings_handle.clone());
            shell.engine.set_on_change(move || {
                p.update_if(|p, _| p.sync());
                s.update_if(|s, _| s.sync());
            });
        }
        if !headless {
            selftest::start(panel_handle.clone());
            open_panel_on_launch(panel_handle.clone());
        }
        // SIGTERM / SIGINT / SIGHUP quit through the normal path, so the cleanup runs.
        shell.engine.set_on_terminate(move || panel_handle.quit());

        let panel_app = panel_app.init({
            let shell = shell.clone();
            move || Panel::new(shell)
        });
        let settings_app = settings_app.init({
            let shell = shell.clone();
            move || Settings::new(shell)
        });

        shell.install_tray();

        let panel_options = WindowOptions {
            visible: false,
            borderless: true,
            transparent: true,
            resizable: false,
            always_on_top: true,
            min_size: Some(PANEL_MIN),
            max_size: Some(PANEL_MAX),
            ..Default::default()
        }
        .macos(
            MacWindowOptions::default()
                .nonactivating_panel(true)
                .corner_radius(ui::PANEL_RADIUS)
                .level(PANEL_LEVEL)
                .collection_behavior(PANEL_COLLECTION),
        );

        vec![
            WindowSpec::from_app("panel", panel_app).configured_options(panel_options).boxed(),
            WindowSpec::from_app("settings", settings_app).boxed(),
        ]
    });
}

/// Runs the engine's on-quit cleanup when dropped by a panic unwinding out of `main` (main
/// thread, after Rune's event loop has stopped).
struct CleanupOnPanic;

impl Drop for CleanupOnPanic {
    fn drop(&mut self) {
        if std::thread::panicking() {
            atmos_core::shutdown_process_engine();
        }
    }
}

/// `ATMOS_OPEN_PANEL=1` (development): open the panel once the menu-bar item has a frame to
/// sit under, as a click on it would. With `ATMOS_DEBUG=1` the shell logs where it opened.
fn open_panel_on_launch(panel: rune::AppHandle<Panel>) {
    if std::env::var_os("ATMOS_OPEN_PANEL").is_none_or(|v| v != "1") { return; }
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(800));
        panel.update(|p, _| p.shell.show_panel());
    });
}
