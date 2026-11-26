//! The app shell shared by both windows: the engine handle, the menu-bar item, which surfaces
//! are on screen (reported to the engine: it gates meter polling and head motion), placing the
//! panel under the menu-bar item, and opening Settings. Main thread only (`Rc`).

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::{Duration, Instant};

use atmos_core::Engine;
use rune::{AppHandle, Display, Tray, TrayEvent, TrayIcon, TrayItem, TraySpec};

use crate::glyph::TrayGlyph;
use crate::panel::Panel;
use crate::settings::Settings;

/// The panel window's width in points; its height follows its content
/// (`App::fit_content_height`), up to the room below the menu bar.
pub const PANEL_WIDTH: f32 = crate::panel::WIDTH;
/// The size the panel window is created at, before its content sets the height.
pub const PANEL_SIZE: (f32, f32) = (PANEL_WIDTH, 520.0);
/// Gap between the menu bar and the panel, and the panel's minimum distance from a screen
/// edge (points).
const PANEL_GAP: f64 = 6.0;
const PANEL_EDGE_MARGIN: f64 = 8.0;
/// Room kept free between the panel and the bottom of the screen (points).
const PANEL_BOTTOM_MARGIN: f64 = 12.0;
/// The content's height limit before the panel has been placed (headless renders): never
/// reached, so a render always shows the whole panel.
const UNPLACED_MAX_HEIGHT: f32 = 4000.0;
/// A tray click this soon after the panel hid on focus loss is the click that hid it: don't
/// reopen.
const REOPEN_GUARD: Duration = Duration::from_millis(400);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Surface {
    Panel,
    Settings,
}

pub struct Shell {
    pub engine: Engine,
    /// A headless tooling run (`--snap`, `--tree`, ...): no tray, both surfaces count as
    /// visible, and the mock runs on the virtual frame clock.
    pub headless: bool,
    panel: AppHandle<Panel>,
    settings: AppHandle<Settings>,
    tray: RefCell<Option<Tray>>,
    icons: [Option<TrayIcon>; 3],
    tray_glyph: Cell<Option<TrayGlyph>>,
    panel_visible: Cell<bool>,
    settings_visible: Cell<bool>,
    panel_hidden_at: Cell<Option<Instant>>,
    /// The tallest the panel's content may be on the display it last opened on (points).
    panel_max_height: Cell<f32>,
    started: Instant,
}

impl Shell {
    pub fn new(engine: Engine, headless: bool, panel: AppHandle<Panel>, settings: AppHandle<Settings>) -> Rc<Shell> {
        let shell = Rc::new(Shell {
            engine,
            headless,
            panel,
            settings,
            tray: RefCell::new(None),
            icons: TrayGlyph::ALL.map(crate::glyph::tray_icon),
            tray_glyph: Cell::new(None),
            panel_visible: Cell::new(headless),
            settings_visible: Cell::new(headless),
            panel_hidden_at: Cell::new(None),
            panel_max_height: Cell::new(UNPLACED_MAX_HEIGHT),
            started: Instant::now(),
        });
        shell.report_visibility();
        shell
    }

    /// Seconds for the mock's clock: the virtual frame clock headless (deterministic frames),
    /// else wall time since launch (both windows share it).
    pub fn clock(&self, frame_clock: f64) -> f64 {
        if self.headless { frame_clock } else { self.started.elapsed().as_secs_f64() }
    }

    // ── Visibility ───────────────────────────────────────────────────────────────────────

    pub fn set_surface_visible(&self, surface: Surface, visible: bool) {
        if self.headless { return; }
        let cell = match surface {
            Surface::Panel => &self.panel_visible,
            Surface::Settings => &self.settings_visible,
        };
        if cell.replace(visible) != visible {
            self.report_visibility();
        }
    }

    /// Tell the engine which surfaces are on screen (also: undo the selftest's override).
    pub fn report_visibility(&self) {
        self.engine.set_visible(self.panel_visible.get(), self.settings_visible.get());
    }

    pub fn panel_visible(&self) -> bool { self.panel_visible.get() }

    /// The tallest the panel's content may be: the room below the menu bar on its display.
    pub fn panel_max_height(&self) -> f32 { self.panel_max_height.get() }

    // ── Panel ────────────────────────────────────────────────────────────────────────────

    /// Primary click on the menu-bar item.
    pub fn toggle_panel(&self) {
        if self.panel_visible.get() {
            self.hide_panel();
        } else if self.panel_hidden_at.get().is_some_and(|t| t.elapsed() < REOPEN_GUARD) {
            // This click is the one that took focus away and hid the panel.
        } else {
            self.show_panel();
        }
    }

    /// The menu-bar item's frame in physical desktop pixels, once it is laid out.
    pub fn tray_rect(&self) -> Option<[i32; 4]> { self.tray.borrow().as_ref().and_then(Tray::rect) }

    pub fn show_panel(&self) {
        let tray = self.tray_rect();
        if let Some(place) = tray.and_then(|r| panel_placement(r, &rune::displays(), PANEL_WIDTH)) {
            self.panel.set_position(place.position);
            if self.panel_max_height.replace(place.max_height) != place.max_height {
                // The view reads the limit: rebuild it for the display it now opens on.
                self.panel.update(|_, _| {});
            }
            if std::env::var_os("ATMOS_DEBUG").is_some() {
                eprintln!("atmos-control: panel at {:?} px, content up to {} pt (menu-bar item {tray:?} px)", place.position, place.max_height);
            }
        }
        // A nonactivating panel: it takes keys (Esc) without activating the app.
        self.panel.open();
        self.set_surface_visible(Surface::Panel, true);
        if let Some(tray) = self.tray.borrow().as_ref() { tray.set_highlighted(true); }
    }

    pub fn hide_panel(&self) {
        self.panel.hide();
        self.panel_hidden_at.set(Some(Instant::now()));
        self.set_surface_visible(Surface::Panel, false);
        if let Some(tray) = self.tray.borrow().as_ref() { tray.set_highlighted(false); }
    }

    // ── Settings ─────────────────────────────────────────────────────────────────────────

    /// Show Settings (one instance) and bring it forward; the panel steps aside.
    pub fn open_settings(&self) {
        if self.panel_visible.get() && !self.headless { self.hide_panel(); }
        self.settings.open();
        self.set_surface_visible(Surface::Settings, true);
    }

    // ── Menu-bar item ────────────────────────────────────────────────────────────────────

    /// Create the status item (main thread, native runs only).
    pub fn install_tray(&self) {
        if self.headless || self.tray.borrow().is_some() { return; }
        let glyph = TrayGlyph::for_snapshot(&self.engine.snapshot());
        let Some(icon) = self.icons[glyph.index()].clone() else {
            eprintln!("atmos-control: menu-bar glyph failed to rasterize");
            return;
        };
        let panel = self.panel.clone();
        let spec = TraySpec::new("dev.atmoscontrol.app", "atmos-control", icon)
            .tooltip("atmos-control")
            .menu(vec![
                TrayItem::action("settings", "Settings…"),
                TrayItem::Separator,
                TrayItem::action("quit", "Quit atmos-control"),
            ]);
        let tray = Tray::new(spec, move |event| match event {
            TrayEvent::Activate { .. } => panel.update(|p, _| p.shell.toggle_panel()),
            TrayEvent::Menu(id) if id == "settings" => panel.update(|p, _| p.shell.open_settings()),
            TrayEvent::Menu(id) if id == "quit" => panel.quit(),
            _ => {}
        });
        match tray {
            Ok(tray) => {
                *self.tray.borrow_mut() = Some(tray);
                self.tray_glyph.set(None);
                self.sync_tray();
            }
            Err(err) => {
                // Without the status item nothing could open the UI: show Settings instead.
                eprintln!("atmos-control: menu-bar item unavailable: {err}");
                self.open_settings();
            }
        }
    }

    /// Match the glyph and tooltip to the engine state (cheap when unchanged).
    pub fn sync_tray(&self) {
        let (glyph, status) = {
            let s = self.engine.snapshot();
            let idle = !s.is_on && !s.busy;
            let status = if idle && s.permission_needed {
                "Needs audio-capture permission".to_owned()
            } else if idle && s.last_error.is_some() {
                "Couldn’t start".to_owned()
            } else {
                s.engine_status_text.clone()
            };
            (TrayGlyph::for_snapshot(&s), status)
        };
        let tray = self.tray.borrow();
        let Some(tray) = tray.as_ref() else { return };
        if self.tray_glyph.replace(Some(glyph)) != Some(glyph)
            && let Some(icon) = self.icons[glyph.index()].clone()
            && let Err(err) = tray.set_icon(icon)
        {
            eprintln!("atmos-control: menu-bar glyph update failed: {err}");
        }
        tray.set_tooltip(format!("atmos-control — {status}"));
    }
}

/// Where the panel opens: its top-left in physical desktop pixels, and the tallest its content
/// may be, in points.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PanelPlacement {
    pub position: (i32, i32),
    pub max_height: f32,
}

/// The panel under the menu-bar item: centred below it, `PANEL_GAP` under the bar, on the
/// display that holds it, kept `PANEL_EDGE_MARGIN` inside that display's left and right edges,
/// and no taller than the room left above its bottom edge. `tray` is the item's frame in
/// physical desktop pixels; points convert with that display's own scale (Retina, mixed setups).
pub fn panel_placement(tray: [i32; 4], displays: &[Display], width_pt: f32) -> Option<PanelPlacement> {
    let [x, y, w, h] = tray;
    let (cx, cy) = (x + w / 2, y + h / 2);
    let inside = |d: &&Display| {
        cx >= d.position.0 && cx < d.position.0 + d.size.0 as i32
            && cy >= d.position.1 && cy < d.position.1 + d.size.1 as i32
    };
    let display = displays.iter().find(inside)
        .or_else(|| displays.iter().find(|d| d.primary))
        .or_else(|| displays.first())?;
    let scale = if display.scale > 0.0 { display.scale } else { 1.0 };
    let width = (f64::from(width_pt) * scale).round() as i32;
    let margin = (PANEL_EDGE_MARGIN * scale).round() as i32;
    let left = display.position.0 + margin;
    let right = (display.position.0 + display.size.0 as i32 - margin - width).max(left);
    let px = (cx - width / 2).clamp(left, right);
    let py = y + h + (PANEL_GAP * scale).round() as i32;
    let bottom = display.position.1 + display.size.1 as i32;
    let max_height = (f64::from(bottom - py) / scale - PANEL_BOTTOM_MARGIN).max(200.0) as f32;
    Some(PanelPlacement { position: (px, py), max_height })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn display(x: i32, w: u32, scale: f64, primary: bool) -> Display {
        Display { id: None, name: None, position: (x, 0), size: (w, 1800), scale, primary }
    }

    fn position(tray: [i32; 4], d: &[Display]) -> (i32, i32) {
        panel_placement(tray, d, 320.0).unwrap().position
    }

    #[test]
    fn panel_centres_under_the_item_and_stays_on_screen() {
        let d = [display(0, 2880, 2.0, true)];
        // Item in the middle of the menu bar.
        assert_eq!(position([1400, 0, 48, 48], &d), (1424 - 320, 60));
        // Near the right edge: clamped 8 pt (16 px) inside.
        assert_eq!(position([2850, 0, 30, 48], &d), (2880 - 16 - 640, 60));
        // Near the left edge: clamped 8 pt inside.
        assert_eq!(position([10, 0, 30, 48], &d), (16, 60));
    }

    #[test]
    fn panel_uses_the_display_that_holds_the_item() {
        let d = [display(0, 2880, 2.0, true), display(2880, 1920, 1.0, false)];
        assert_eq!(position([4700, 0, 24, 24], &d), (2880 + 1920 - 8 - 320, 30));
    }

    #[test]
    fn panel_height_is_capped_by_the_room_below_the_bar() {
        // 1800 px at 2x is 900 pt; the panel's top is 60 px (30 pt) down; 12 pt stay free.
        let p = panel_placement([1400, 0, 48, 48], &[display(0, 2880, 2.0, true)], 332.0).unwrap();
        assert_eq!(p.max_height, 900.0 - 30.0 - 12.0);
    }
}
