//! The app shell shared by both windows: the engine handle, the menu-bar item, which surfaces
//! are on screen (reported to the engine: it gates meter polling and head motion), placing the
//! panel under the menu-bar item, and opening Settings. Main thread only (`Rc`).

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::{Duration, Instant};

use atmos_core::Engine;
use rune::{AppHandle, Display, Tray, TrayEvent, TrayIcon, TrayItem, TraySpec};

use crate::panel::Panel;
use crate::settings::Settings;

/// Logical size of the panel window (points). The views agent may make it fit its content.
pub const PANEL_SIZE: (f32, f32) = (320.0, 420.0);
/// Gap between the menu bar and the panel, and the panel's minimum distance from a screen
/// edge (points).
const PANEL_GAP: f64 = 6.0;
const PANEL_EDGE_MARGIN: f64 = 8.0;
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
    icons: [Option<TrayIcon>; 2],
    tray_on: Cell<Option<bool>>,
    panel_visible: Cell<bool>,
    settings_visible: Cell<bool>,
    panel_hidden_at: Cell<Option<Instant>>,
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
            icons: [crate::glyph::tray_icon(false), crate::glyph::tray_icon(true)],
            tray_on: Cell::new(None),
            panel_visible: Cell::new(headless),
            settings_visible: Cell::new(headless),
            panel_hidden_at: Cell::new(None),
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
        if let Some(position) = self.tray_rect().and_then(|r| panel_position(r, &rune::displays(), PANEL_SIZE)) {
            self.panel.set_position(position);
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

    /// Show Settings (one instance) and bring it forward.
    pub fn open_settings(&self) {
        self.settings.open();
        self.set_surface_visible(Surface::Settings, true);
    }

    // ── Menu-bar item ────────────────────────────────────────────────────────────────────

    /// Create the status item (main thread, native runs only).
    pub fn install_tray(&self) {
        if self.headless || self.tray.borrow().is_some() { return; }
        let Some(icon) = self.icons[usize::from(self.engine.snapshot().is_on)].clone() else {
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
                self.tray_on.set(None);
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
        let (on, status) = {
            let s = self.engine.snapshot();
            (s.is_on, s.engine_status_text.clone())
        };
        let tray = self.tray.borrow();
        let Some(tray) = tray.as_ref() else { return };
        if self.tray_on.replace(Some(on)) != Some(on)
            && let Some(icon) = self.icons[usize::from(on)].clone()
            && let Err(err) = tray.set_icon(icon)
        {
            eprintln!("atmos-control: menu-bar glyph update failed: {err}");
        }
        tray.set_tooltip(format!("atmos-control — {status}"));
    }
}

/// Top-left of the panel in physical desktop pixels: centred under the menu-bar item, on the
/// display that holds it, kept `PANEL_EDGE_MARGIN` inside its left and right edges.
pub fn panel_position(tray: [i32; 4], displays: &[Display], size_pt: (f32, f32)) -> Option<(i32, i32)> {
    let [x, y, w, h] = tray;
    let (cx, cy) = (x + w / 2, y + h / 2);
    let inside = |d: &&Display| {
        cx >= d.position.0 && cx < d.position.0 + d.size.0 as i32
            && cy >= d.position.1 && cy < d.position.1 + d.size.1 as i32
    };
    let display = displays.iter().find(inside)
        .or_else(|| displays.iter().find(|d| d.primary))
        .or_else(|| displays.first())?;
    let scale = display.scale;
    let width = (f64::from(size_pt.0) * scale).round() as i32;
    let margin = (PANEL_EDGE_MARGIN * scale).round() as i32;
    let left = display.position.0 + margin;
    let right = (display.position.0 + display.size.0 as i32 - margin - width).max(left);
    let px = (cx - width / 2).clamp(left, right);
    let py = y + h + (PANEL_GAP * scale).round() as i32;
    Some((px, py))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn display(x: i32, w: u32, scale: f64, primary: bool) -> Display {
        Display { id: None, name: None, position: (x, 0), size: (w, 1800), scale, primary }
    }

    #[test]
    fn panel_centres_under_the_item_and_stays_on_screen() {
        let d = [display(0, 2880, 2.0, true)];
        // Item in the middle of the menu bar.
        assert_eq!(panel_position([1400, 0, 48, 48], &d, (320.0, 420.0)), Some((1424 - 320, 60)));
        // Item near the right edge: clamped 8 pt (16 px) inside.
        assert_eq!(panel_position([2850, 0, 30, 48], &d, (320.0, 420.0)), Some((2880 - 16 - 640, 60)));
    }

    #[test]
    fn panel_uses_the_display_that_holds_the_item() {
        let d = [display(0, 2880, 2.0, true), display(2880, 1920, 1.0, false)];
        let (x, y) = panel_position([4700, 0, 24, 24], &d, (320.0, 420.0)).unwrap();
        assert_eq!((x, y), (2880 + 1920 - 8 - 320, 30));
    }
}
