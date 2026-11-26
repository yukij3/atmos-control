//! The Settings window: an ordinary titled window, one instance, opened from the menu-bar menu,
//! the panel, or ⌘,. A native macOS grouped form (DESIGN.md "Settings window") that scrolls
//! inside the window:
//!
//! - the engine group: power, its state in words, and the permission, driver and error notices,
//!   so Settings is never blind to why audio isn't spatialized (audit L17);
//! - Output: audio capture, output device, output type;
//! - Soundstage: the large draggable radar with the elevation gauge, then the source controls;
//! - Personalization: head tracking, HRTF mode, the personalized-HRTF status;
//! - Rendering: algorithm, distance model and reverb, collapsed by default;
//! - Levels: L/R or 12-channel meters.
//!
//! `form` holds the row vocabulary (rune-kit controls on atmos-kit tokens), `sections` the
//! content.

mod form;
mod sections;

use std::rc::Rc;
use std::time::Duration;

use atmos_core::MockPreset;
use rune::{Cx, El, Key, KeyEvent, ScrollSpec, Tx, col, el};
use rune_kit::ScrollBar;

use crate::shell::{Shell, Surface};
use crate::ui;
use form::{Form, PAD_X, SECTION_GAP};

/// Default size: the engine group, Output and the whole radar show without scrolling.
pub const SIZE: (f32, f32) = (560.0, 760.0);
/// Narrower than this the slider rows run out of room for their labels.
pub const MIN_SIZE: (f32, f32) = (500.0, 420.0);

pub struct Settings {
    pub shell: Rc<Shell>,
    seen: u64,
    /// The Rendering section is open (collapsed by default; not persisted).
    pub rendering_open: bool,
    /// `ATMOS_DEBUG` set: show the ring-buffer counters under Levels.
    debug: bool,
}

impl Settings {
    pub fn new(shell: Rc<Shell>) -> Settings {
        let debug = std::env::var_os("ATMOS_DEBUG").is_some_and(|v| !v.is_empty() && v != "0");
        Settings { shell, seen: 0, rendering_open: false, debug }
    }

    pub fn sync(&mut self) -> bool {
        let generation = self.shell.engine.generation();
        if generation == self.seen { return false; }
        self.seen = generation;
        true
    }
}

pub fn poll(s: &mut Settings, t: f64, tx: &mut Tx) -> bool {
    let engine = &s.shell.engine;
    engine.tick(s.shell.clock(t));
    if engine.wants_ticks() { tx.wake_after(Duration::from_millis(33)); }
    s.sync()
}

pub fn on_key(_: &mut Settings, ev: &KeyEvent, tx: &mut Tx) -> bool {
    match ev.key {
        Key::Command('w') => tx.close_window(),
        Key::Command('q') => tx.quit(),
        _ => return false,
    }
    true
}

pub fn on_visibility(s: &mut Settings, visible: bool, _: &mut Tx) {
    s.shell.set_surface_visible(Surface::Settings, visible);
}

pub fn on_close(s: &mut Settings, _: &mut Tx) {
    s.shell.set_surface_visible(Surface::Settings, false);
}

fn preset(s: &mut Settings, p: MockPreset) {
    s.shell.engine.mock_preset(p);
    s.rendering_open = false;
}

pub const SCENES: ui::Scenes<Settings> = &[
    ("playing", |s| preset(s, MockPreset::Playing)),
    ("off", |s| preset(s, MockPreset::Off)),
    ("starting", |s| preset(s, MockPreset::Starting)),
    ("permission", |s| preset(s, MockPreset::PermissionNeeded)),
    ("error", |s| preset(s, MockPreset::Error)),
    ("speakers", |s| preset(s, MockPreset::Speakers)),
    ("surround", |s| preset(s, MockPreset::Surround)),
    // The Rendering section open, over the playing state.
    ("rendering", |s| {
        preset(s, MockPreset::Playing);
        s.rendering_open = true;
    }),
];

pub fn view(st: &Settings, cx: &mut Cx<Settings>) -> El {
    let f = Form::new(cx);
    let engine = &st.shell.engine;
    // Defaults first: `snapshot` may re-read the engine, which needs the backend unborrowed.
    let defaults = engine.defaults();
    let s = engine.snapshot();

    let content = col().key("settings-scroll").w_full().grow(1.0).min_h(0.0)
        .scroll(ScrollSpec::default())
        .px(PAD_X).pt(16.0).gap(SECTION_GAP)
        .child(sections::status(&f, &s, engine))
        .child(sections::output(&f, &s))
        .child(sections::soundstage(&f, &s, &defaults))
        .child(sections::personalization(&f, &s))
        .child(sections::rendering(&f, &s, &defaults, st.rendering_open))
        .child(sections::levels(&f, &s, st.debug))
        // Room under the last group: a scroll viewport's bottom padding isn't part of what it
        // scrolls through, so the end would sit flush with the window's edge.
        .child(el().key("end").h(6.0).a11y_hidden())
        .scroll_bar(&f.k);

    col().key("settings").w_full().h_full().fill(f.t.c.surface_window).child(content)
}
