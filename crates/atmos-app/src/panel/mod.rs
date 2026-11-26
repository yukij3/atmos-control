//! The menu-bar panel: a borderless, nonactivating Liquid Glass window under the menu-bar
//! item, as tall as its content. Primary click on the item toggles it; Esc, ⌘W or clicking
//! elsewhere hides it. ⌘, opens Settings, ⌘Q quits.
//!
//! - `status`: what the panel says about the engine (rows, notices, recovery actions).
//! - `view`: the layout (header + power, status, soundstage, quick controls, footer).

mod status;
mod view;

use std::rc::Rc;
use std::time::Duration;

use atmos_core::MockPreset;
use rune::{Key, KeyEvent, Tx};

use crate::shell::{Shell, Surface};
use crate::ui;

pub use view::{WIDTH, view};

/// A Personalized start still in "Starting…" after this long is most likely held by the macOS
/// audio-capture prompt (the first start asks; the engine can't tell the two apart), so the
/// panel says so and offers Privacy & Security instead of a bare "Starting…".
const PERMISSION_HINT_AFTER: f64 = 2.0;

pub struct Panel {
    pub shell: Rc<Shell>,
    /// The engine generation this window last drew.
    seen: u64,
    /// When the current Personalized start began (`Shell::clock` seconds).
    starting_since: Option<f64>,
    /// The start has lasted past `PERMISSION_HINT_AFTER`.
    waiting_for_permission: bool,
}

impl Panel {
    pub fn new(shell: Rc<Shell>) -> Panel {
        Panel { shell, seen: 0, starting_since: None, waiting_for_permission: false }
    }

    /// Catch up with the engine: true when the view must rebuild. Also keeps the menu-bar
    /// glyph current (this runs even while the panel is hidden).
    pub fn sync(&mut self) -> bool {
        let generation = self.shell.engine.generation();
        if generation == self.seen { return false; }
        self.seen = generation;
        self.shell.sync_tray();
        true
    }

    /// Track how long a Personalized start has run; true when the permission hint flips.
    fn watch_start(&mut self, now: f64, tx: &mut Tx) -> bool {
        let can_wait = status::start_can_wait_for_permission(&self.shell.engine.snapshot());
        self.starting_since = match (can_wait, self.starting_since) {
            (true, None) => Some(now),
            (true, since) => since,
            (false, _) => None,
        };
        let waiting = self.starting_since.is_some_and(|t0| now - t0 >= PERMISSION_HINT_AFTER);
        if let Some(t0) = self.starting_since.filter(|_| !waiting) {
            tx.wake_after(Duration::from_secs_f64((t0 + PERMISSION_HINT_AFTER - now).max(0.05)));
        }
        self.waiting_for_permission != waiting && {
            self.waiting_for_permission = waiting;
            true
        }
    }
}

/// Every frame and every wake: the mock's clock, the change check and the start watch.
pub fn poll(p: &mut Panel, t: f64, tx: &mut Tx) -> bool {
    let now = p.shell.clock(t);
    let engine = &p.shell.engine;
    engine.tick(now);
    if engine.wants_ticks() { tx.wake_after(Duration::from_millis(33)); }
    let changed = p.sync();
    p.watch_start(now, tx) || changed
}

pub fn on_key(p: &mut Panel, ev: &KeyEvent, tx: &mut Tx) -> bool {
    match ev.key {
        Key::Escape | Key::Command('w') => p.shell.hide_panel(),
        Key::Command(',') => p.shell.open_settings(),
        Key::Command('q') => tx.quit(),
        _ => return false,
    }
    true
}

/// Popover behaviour: clicking anywhere else hides the panel.
pub fn on_focus(p: &mut Panel, focused: bool, _: &mut Tx) {
    if !focused && p.shell.panel_visible() { p.shell.hide_panel(); }
}

pub fn on_visibility(p: &mut Panel, visible: bool, _: &mut Tx) {
    p.shell.set_surface_visible(Surface::Panel, visible);
}

/// `--scene <name>` for headless renders (mock engine). `waiting` is a Personalized start held
/// by the audio-capture prompt (the hint shows at once).
pub const SCENES: ui::Scenes<Panel> = &[
    ("playing", |p| p.shell.engine.mock_preset(MockPreset::Playing)),
    ("off", |p| p.shell.engine.mock_preset(MockPreset::Off)),
    ("starting", |p| p.shell.engine.mock_preset(MockPreset::Starting)),
    ("waiting", |p| {
        p.shell.engine.mock_preset(MockPreset::Starting);
        p.starting_since = Some(f64::NEG_INFINITY);
    }),
    ("permission", |p| p.shell.engine.mock_preset(MockPreset::PermissionNeeded)),
    ("error", |p| p.shell.engine.mock_preset(MockPreset::Error)),
    ("speakers", |p| p.shell.engine.mock_preset(MockPreset::Speakers)),
    ("surround", |p| p.shell.engine.mock_preset(MockPreset::Surround)),
];
