//! The Settings window's form vocabulary: a native macOS grouped form (System Settings), built
//! from rune-kit controls seeded with atmos-kit's tokens. Sections are a quiet header, one
//! rounded group of rows with inset hairlines, and an optional footnote; rows are a label (with
//! an optional subtitle that says why a control is off) and a trailing control. Slider rows put
//! the slider and an SF Mono readout in fixed columns, so every value in the window lines up.

use atmos_kit::theme::{SANS, srgba};
use atmos_kit::{Theme, ty};
use rune::{Align, Color, Cx, El, Icon, PopupItem, PopupMenu, TextStyle, Tx, col, el, icon, row, text};
use rune_kit::{Button, Kit, PaletteFocus, PaletteSeed, Select, Slider, Switch};

use super::Settings;

// ── Layout tokens (points) ──────────────────────────────────────────────────────────────────

/// Window content inset, left and right.
pub const PAD_X: f32 = 20.0;
/// Row content inset inside a group; section headers and footnotes align to it.
pub const INSET: f32 = 12.0;
/// Between sections.
pub const SECTION_GAP: f32 = 22.0;
/// Header to group, group to footnote.
const HEADER_GAP: f32 = 6.0;
/// A one-line row's height.
const ROW_H: f32 = 38.0;
const ROW_PAD_Y: f32 = 8.0;
const GROUP_RADIUS: f32 = 10.0;
/// Slider track width; every slider row shares it so the knobs' travel lines up.
const SLIDER_W: f32 = 220.0;
/// The readout column after a slider: room for "−180°", "−40 dB", "20.0 m", "100 %".
const READOUT_W: f32 = 52.0;
/// The widest a picker's value may draw before it truncates.
const PICKER_MAX_W: f32 = 250.0;

/// Section headers: the native grouped form's (13 pt semibold, label colour), one per group;
/// never tracked capitals.
pub const HEADER: TextStyle = TextStyle::new(13.0, 600.0).family(SANS).lh(16.0);
/// Row labels.
const LABEL: TextStyle = TextStyle::new(13.0, 400.0).family(SANS).lh(16.0);
/// Row subtitles and section footnotes.
const NOTE: TextStyle = TextStyle::new(11.0, 400.0).family(SANS).lh(14.0);

// ── Icons (authored on a 16 pt grid, one 1.3 pt stroke) ─────────────────────────────────────

/// A pop-up button's up-and-down chevrons (AppKit's `chevron.up.chevron.down`).
pub static CHEVRONS: Icon = Icon {
    name: "atmos-chevrons-up-down",
    view: 16.0,
    body: r#"<path d="M5.25 6.25L8 3.5L10.75 6.25M5.25 9.75L8 12.5L10.75 9.75" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
};
/// The Rendering disclosure, closed and open.
pub static DISCLOSE_CLOSED: Icon = Icon {
    name: "atmos-disclose-closed",
    view: 16.0,
    body: r#"<path d="M6.25 3.75L10.5 8L6.25 12.25" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
};
pub static DISCLOSE_OPEN: Icon = Icon {
    name: "atmos-disclose-open",
    view: 16.0,
    body: r#"<path d="M3.75 6.25L8 10.5L12.25 6.25" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
};
/// A blocking problem the user can fix (permission, a missing driver).
pub static WARN: Icon = Icon {
    name: "atmos-warn",
    view: 16.0,
    body: r#"<path d="M8 2.4L14.3 13.3H1.7Z" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" fill="none"/><path d="M8 6.4V9.5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="11.45" r="0.85" fill="currentColor"/>"#,
};
/// An error the engine reported.
pub static ERROR: Icon = Icon {
    name: "atmos-error",
    view: 16.0,
    body: r#"<circle cx="8" cy="8" r="6.1" stroke="currentColor" stroke-width="1.3" fill="none"/><path d="M8 4.7V8.6" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="10.95" r="0.85" fill="currentColor"/>"#,
};

// ── The form's paint: atmos-kit tokens + a rune-kit Kit seeded from them ───────────────────

/// Everything a row needs to paint itself.
pub struct Form {
    pub t: Theme,
    pub k: Kit,
    /// One device pixel.
    pub hair: f32,
}

impl Form {
    pub fn new(cx: &Cx<Settings>) -> Form {
        let t = Theme::from_cx(cx);
        let (bg, fg, accent) = t.kit_seed(true);
        // Focus rings follow the system accent, as AppKit's do.
        let mut k = Kit::from_palette_focus(PaletteSeed { bg, fg, accent }, PaletteFocus::Custom(cx.focus_color()));
        // Kit text in SF Pro whatever the app's default family is.
        let sans = |s: TextStyle| s.family(SANS);
        k.ty.ui = sans(LABEL.lh(20.0));
        k.ty.ui_medium = sans(LABEL.lh(20.0));
        k.ty.ui_compact = sans(LABEL);
        k.ty.small = sans(k.ty.small);
        k.ty.small_medium = sans(k.ty.small_medium);
        // The Rendering disclosure's title is a section header like the others.
        k.ty.text_small_medium = HEADER;
        k.metrics.disclosure_header_height = Some(24.0);
        // Pop-up buttons draw AppKit's up-down chevrons.
        k.glyph.chevron_down = &CHEVRONS;
        k.glyph.chevron_up = &CHEVRONS;
        // The disclosure draws chevrons (macOS 26), not the web's triangles.
        k.glyph.triangle_right = &DISCLOSE_CLOSED;
        k.glyph.triangle_down = &DISCLOSE_OPEN;
        // `from_palette` paints knobs in the foreground ink, which is near black in light mode;
        // AppKit's switch and slider knobs are white there.
        if !t.dark {
            k.c.knob = Color::WHITE;
            k.c.knob_on = Color::WHITE;
        }
        Form { t, k, hair: 1.0 / cx.env().scale.max(1.0) }
    }

    fn ink(&self, enabled: bool) -> Color {
        if enabled { self.t.c.ink } else { self.t.c.ink_tertiary }
    }

    /// The grouped box: a faint lift off the window background and a hairline edge.
    fn group_fill(&self) -> (Color, Color) {
        let hc = self.t.increased_contrast;
        if self.t.dark {
            (srgba(0xffffff, 0.045), srgba(0xffffff, if hc { 0.16 } else { 0.07 }))
        } else {
            (srgba(0xffffff, 0.62), srgba(0x000000, if hc { 0.18 } else { 0.08 }))
        }
    }

    // ── Sections ────────────────────────────────────────────────────────────────────────

    /// A titled section: header, group, optional footnote.
    pub fn section(&self, key: &'static str, title: &str, rows: Vec<El>, footnote: Option<&str>) -> El {
        col().key(key).role("group").label(title.to_owned()).w_full().gap(HEADER_GAP)
            .child(self.header(title))
            .child(self.group(rows))
            .children(footnote.map(|f| self.footnote(f)))
    }

    pub fn header(&self, title: &str) -> El {
        text(title.to_owned()).key("header").font(HEADER).color(self.t.c.ink).px(INSET).a11y_hidden()
    }

    /// Secondary, leading, footnote size (audit V9: never body size or trailing).
    pub fn footnote(&self, s: &str) -> El {
        text(s.to_owned()).key("footnote").w_full().wrap().font(NOTE).color(self.t.c.ink_secondary).px(INSET)
    }

    /// Rows in one rounded group, separated by hairlines inset to the row content.
    pub fn group(&self, rows: Vec<El>) -> El {
        let (fill, edge) = self.group_fill();
        let n = rows.len();
        let mut g = col().key("group").w_full().radius(GROUP_RADIUS).fill(fill).border(self.hair, edge);
        for (i, r) in rows.into_iter().enumerate() {
            g = g.child(r);
            if i + 1 < n {
                g = g.child(el().key(format!("sep{i}")).h(self.hair).mx(INSET).fill(self.t.c.separator).a11y_hidden());
            }
        }
        g
    }

    // ── Rows ────────────────────────────────────────────────────────────────────────────

    /// The label column: the label, and under it a subtitle in secondary ink (the reason a
    /// control is off, or what a choice means). A disabled row's label dims with its control
    /// (audit V11); the reason stays readable.
    fn label_col(&self, label: &str, subtitle: Option<&str>, enabled: bool) -> El {
        col().key("text").grow(1.0).shrink().min_w(0.0).gap(2.0)
            .child(text(label.to_owned()).key("label").font(LABEL).color(self.ink(enabled)))
            .children(subtitle.map(|s| text(s.to_owned()).key("subtitle").w_full().wrap().font(NOTE).color(self.t.c.ink_secondary)))
    }

    fn row_shell(&self, key: impl Into<String>) -> El {
        row().key(key.into()).w_full().min_h(ROW_H).px(INSET).py(ROW_PAD_Y).gap(12.0).center_y()
    }

    /// A label (and subtitle) with a trailing control or value.
    pub fn row(&self, key: impl Into<String>, label: &str, subtitle: Option<&str>, enabled: bool, trailing: El) -> El {
        self.row_shell(key).child(self.label_col(label, subtitle, enabled)).child(trailing)
    }

    /// A row whose trailing side is plain text (a read-only value).
    pub fn value_row(&self, key: impl Into<String>, label: &str, subtitle: Option<&str>, value: &str) -> El {
        let v = text(value.to_owned()).key("value").font(LABEL).color(self.t.c.ink_secondary).truncate().max_w(PICKER_MAX_W);
        self.row(key, label, subtitle, true, v)
    }

    /// A row whose trailing side is a mono readout.
    pub fn readout_row(&self, key: impl Into<String>, label: &str, value: &str, enabled: bool) -> El {
        let v = text(value.to_owned()).key("value").font(ty::READOUT).color(self.ink(enabled)).nowrap();
        self.row(key, label, None, enabled, v)
    }

    /// A switch row. `toggle` flips the setting (read the current value from the engine there).
    pub fn switch_row(&self, key: &'static str, label: &str, subtitle: Option<&str>, on: bool, enabled: bool, toggle: fn(&mut Settings)) -> El {
        let mut sw = Switch::new(on).label(label.to_owned()).hide_label().disabled(!enabled);
        if enabled {
            sw = sw.on_toggle(toggle);
        }
        self.row(key, label, subtitle, enabled, sw.build(&self.k).key(format!("{key}-switch")))
    }

    /// A pop-up button row (see [`Form::picker`]).
    pub fn picker_row(&self, key: &'static str, label: &str, subtitle: Option<&str>, picker: Picker) -> El {
        let enabled = picker.enabled;
        self.row(key, label, subtitle, enabled, self.picker(key, label, picker))
    }

    /// A slider row: label column, then the slider and its mono readout in fixed columns. A
    /// double-click on the readout puts the default back.
    pub fn slider_row(&self, key: &'static str, label: &str, subtitle: Option<&str>, s: SliderSpec) -> El {
        let SliderSpec { value, min, max, step, readout, enabled, reset_help, on_change, on_reset } = s;
        let mut slider = Slider::new(format!("{key}-slider"), value)
            .range(min..=max.max(min))
            .step(step)
            .label(label.to_owned())
            .hide_label()
            .value_text(readout.clone())
            .width(SLIDER_W)
            .disabled(!enabled);
        if enabled {
            slider = slider.on_change(on_change);
        }
        let mut value_el = text(readout).key(format!("{key}-value")).w(READOUT_W).font(ty::READOUT).color(self.ink(enabled))
            .align(Align::End).nowrap();
        if enabled {
            value_el = value_el.help(reset_help).on_double_press(on_reset);
        }
        self.row_shell(key)
            .child(self.label_col(label, subtitle, enabled))
            .child(slider.build(&self.k))
            .child(value_el.a11y_hidden())
    }

    /// A row holding one leading push button (the Reset actions; audit V10: leading, both).
    pub fn button_row(&self, key: &'static str, label: &str, help: &str, enabled: bool, press: fn(&mut Settings)) -> El {
        let mut b = Button::new(label.to_owned()).help(help.to_owned()).disabled(!enabled);
        if enabled {
            b = b.on_press(press);
        }
        row().key(key).w_full().min_h(ROW_H).px(INSET).py(ROW_PAD_Y).center_y().child(b.build(&self.k))
    }

    /// A push button for notice rows.
    pub fn button(&self, label: &str, press: fn(&mut Settings)) -> El {
        Button::new(label.to_owned()).on_press(press).build(&self.k)
    }

    /// A notice: a leading glyph in its colour (shape and text carry the meaning, never colour
    /// alone), a title, an optional detail line, optional actions.
    pub fn notice(&self, key: &'static str, glyph: &'static Icon, tint: Color, title: &str, detail: Option<&str>, actions: Vec<El>) -> El {
        let body = col().key("text").grow(1.0).shrink().min_w(0.0).gap(3.0)
            .child(text(title.to_owned()).key("title").w_full().wrap().font(LABEL).color(self.t.c.ink))
            .children(detail.map(|d| text(d.to_owned()).key("detail").w_full().wrap().font(NOTE).color(self.t.c.ink_secondary)))
            .children((!actions.is_empty()).then(|| row().key("actions").pt(5.0).gap(8.0).flex_wrap().children(actions)));
        row().key(key).role("status").w_full().min_h(ROW_H).px(INSET).py(10.0).gap(8.0).items_start()
            .child(el().key("glyph").size(16.0, 16.0).center().a11y_hidden().child(icon(glyph, 16.0).color(tint)))
            .child(body)
    }

    /// A small status word with an accent dot when it's live (text and shape, not colour alone).
    pub fn status(&self, key: &'static str, word: &str, live: bool) -> El {
        let ink = if live { self.t.c.ink } else { self.t.c.ink_secondary };
        row().key(key).gap(6.0).center_y()
            .children(live.then(|| el().key("dot").size(7.0, 7.0).radius(3.5).fill(self.t.c.accent).a11y_hidden()))
            .child(text(word.to_owned()).key("word").font(LABEL).color(ink).nowrap())
    }

    // ── Pickers: a rune-kit pop-up button that opens a native menu ─────────────────────────

    /// A pop-up button: the kit's inline Select trigger (value + chevrons), opening an `NSMenu`
    /// with the current item checked and placed over the button, as AppKit's pop-up buttons and
    /// SwiftUI's menu pickers do. Unavailable choices show greyed out with the reason in their
    /// title.
    pub fn picker(&self, key: &'static str, label: &str, p: Picker) -> El {
        let Picker { current, title, choices, separator_after_first, enabled, pick } = p;
        let mut sel = Select::new(key, &[title.as_str()]).current(Some(title.as_str())).label(label.to_owned()).disabled(!enabled);
        if enabled {
            let anchor = format!("{key}-trigger");
            sel = sel.on_toggle_tx(move |_: &mut Settings, tx: &mut Tx| {
                let mut menu = PopupMenu::new();
                for (i, c) in choices.iter().enumerate() {
                    menu = menu.item(PopupItem::new(c.id.clone(), c.title.clone()).enabled(c.enabled).checked(c.id == current));
                    if i == 0 && separator_after_first {
                        menu = menu.separator();
                    }
                }
                tx.popup_menu(menu.selected(current.clone()), anchor.as_str(), move |s: &mut Settings, picked, _| {
                    if let Some(id) = picked {
                        pick(s, id);
                    }
                });
            });
        }
        sel.trigger(&self.k).max_w(PICKER_MAX_W)
    }
}

/// One menu item of a [`Picker`].
#[derive(Clone, Debug)]
pub struct Choice {
    pub id: String,
    pub title: String,
    pub enabled: bool,
}

impl Choice {
    pub fn new(id: impl Into<String>, title: impl Into<String>) -> Choice {
        Choice { id: id.into(), title: title.into(), enabled: true }
    }
    pub fn enabled(mut self, on: bool) -> Choice {
        self.enabled = on;
        self
    }
}

pub struct Picker {
    /// The checked item's id.
    pub current: String,
    /// What the button shows.
    pub title: String,
    pub choices: Vec<Choice>,
    /// A separator after the first item ("Follow System Default", then the devices).
    pub separator_after_first: bool,
    pub enabled: bool,
    pub pick: fn(&mut Settings, &str),
}

impl Picker {
    pub fn new(current: impl Into<String>, title: impl Into<String>, choices: Vec<Choice>, pick: fn(&mut Settings, &str)) -> Picker {
        Picker { current: current.into(), title: title.into(), choices, separator_after_first: false, enabled: true, pick }
    }
    pub fn enabled(mut self, on: bool) -> Picker {
        self.enabled = on;
        self
    }
    pub fn separator_after_first(mut self) -> Picker {
        self.separator_after_first = true;
        self
    }
}

pub struct SliderSpec {
    pub value: f32,
    pub min: f32,
    pub max: f32,
    pub step: f32,
    pub readout: String,
    pub enabled: bool,
    /// The readout's tooltip ("Double-click to reset to 1.0 m").
    pub reset_help: String,
    /// `(state, value, done)`: `done` on release, keyboard steps and assistive actions.
    pub on_change: fn(&mut Settings, f32, bool),
    pub on_reset: fn(&mut Settings),
}
