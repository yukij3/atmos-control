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

pub struct Panel {
    pub shell: Rc<Shell>,
    /// The engine generation this window last drew.
    seen: u64,
}

impl Panel {
    pub fn new(shell: Rc<Shell>) -> Panel { Panel { shell, seen: 0 } }

    /// Catch up with the engine: true when the view must rebuild. Also keeps the menu-bar
    /// glyph current (this runs even while the panel is hidden).
    pub fn sync(&mut self) -> bool {
        let generation = self.shell.engine.generation();
        if generation == self.seen { return false; }
        self.seen = generation;
        self.shell.sync_tray();
        true
    }
}

/// Every frame and every wake: the mock's clock and the change check.
pub fn poll(p: &mut Panel, t: f64, tx: &mut Tx) -> bool {
    let engine = &p.shell.engine;
    engine.tick(p.shell.clock(t));
    if engine.wants_ticks() { tx.wake_after(Duration::from_millis(33)); }
    p.sync()
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
/// by the macOS audio-capture prompt.
pub const SCENES: ui::Scenes<Panel> = &[
    ("playing", |p| p.shell.engine.mock_preset(MockPreset::Playing)),
    ("off", |p| p.shell.engine.mock_preset(MockPreset::Off)),
    ("starting", |p| p.shell.engine.mock_preset(MockPreset::Starting)),
    ("waiting", |p| p.shell.engine.mock_preset(MockPreset::AwaitingConsent)),
    ("permission", |p| p.shell.engine.mock_preset(MockPreset::PermissionNeeded)),
    ("error", |p| p.shell.engine.mock_preset(MockPreset::Error)),
    ("speakers", |p| p.shell.engine.mock_preset(MockPreset::Speakers)),
    ("surround", |p| p.shell.engine.mock_preset(MockPreset::Surround)),
];
