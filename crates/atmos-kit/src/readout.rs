//! The readout line under the radar: `az +30° · el 0° · 1.0 m` in SF Mono.
//!
//! Each field (`az +30°`) keeps its label against its value and sits centred in a cell as wide
//! as the field's widest text (`az −180°`), so the line reads naturally (no run of padding
//! between a label and a short value) and still keeps one width while the values change: the
//! separators never move and nothing reflows; a value that gains a digit re-centres inside its
//! own cell only.

use rune::{El, row, text};

use crate::format::{self, MINUS};
use crate::stage::Soundstage;
use crate::theme::{Theme, space, ty};

/// U+00A0 NO-BREAK SPACE between a field's label and its value (one SF Mono cell).
const GAP: &str = "\u{a0}";

/// The source readout.
pub struct Readout {
    stage: Soundstage,
    key: &'static str,
}

impl Readout {
    pub fn new(stage: Soundstage) -> Readout {
        Readout { stage, key: "readout" }
    }
    pub fn key(mut self, key: &'static str) -> Self {
        self.key = key;
        self
    }

    /// Labels in secondary ink, values in primary ink, separators in tertiary ink.
    pub fn build(self, t: &Theme) -> El {
        let s = self.stage.clamped();
        let dist = s.mode.uses_distance().then_some(s.distance);
        let az_widest = format!("az{GAP}{MINUS}180°");
        let el_widest = format!("el{GAP}+90°");
        let dist_widest = "0.35 m";
        // A narrow separator: the cells' own slack already spaces the usual short values, and
        // 4 pt either side keeps the widest ones apart.
        let sep = |key: &'static str| {
            text("·").key(key).font(ty::READOUT).color(t.c.ink_tertiary).nowrap().px(space::XS).a11y_hidden()
        };
        row()
            .key(self.key)
            .role("group")
            .label(format::spoken_position(s.azimuth, s.elevation, dist))
            .center_y()
            .child(cell("az", &az_widest, Some("az"), format::degrees(s.azimuth), t))
            .child(sep("s1"))
            .child(cell("el", &el_widest, Some("el"), format::degrees(s.elevation), t))
            .child(sep("s2"))
            .child(cell("d", dist_widest, None, dist.map_or_else(|| "far".to_owned(), format::metres), t))
    }
}

/// One field centred in a cell sized by `widest` (laid out invisibly, so the cell measures the
/// real font rather than an assumed advance).
fn cell(key: &'static str, widest: &str, label: Option<&str>, value: String, t: &Theme) -> El {
    let sizer = text(widest.to_owned()).key("sizer").font(ty::READOUT).nowrap().opacity(0.0).a11y_hidden();
    let shown = row()
        .key("field")
        .absolute(0.0, 0.0)
        .w_full()
        .h_full()
        .justify_center()
        .center_y()
        .a11y_hidden()
        .children(label.map(|l| text(format!("{l}{GAP}")).key("label").font(ty::READOUT).color(t.c.ink_secondary).nowrap()))
        .child(text(value).key("value").font(ty::READOUT).color(t.c.ink).nowrap());
    rune::el().key(key).child(sizer).child(shown)
}
