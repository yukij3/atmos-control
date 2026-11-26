//! The readout line under the radar: `az +30° · el 0° · 1.0 m` in SF Mono. Each value sits
//! right-aligned in a field as wide as its widest value, so the line keeps one width while the
//! values change: nothing jitters, nothing reflows.

use rune::{El, row, text};

use crate::format;
use crate::stage::Soundstage;
use crate::theme::{Theme, ty};

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

    /// Labels and separators in secondary ink, values in primary ink.
    pub fn build(self, t: &Theme) -> El {
        let s = self.stage.clamped();
        let dist = s.mode.uses_distance().then_some(s.distance);
        let [a, e, d] = format::readout_fields(s.azimuth, s.elevation, dist);
        let part = |key: &'static str, s: String, c| text(s).key(key).font(ty::READOUT).color(c).nowrap();
        row()
            .key(self.key)
            .role("group")
            .label(format::spoken_position(s.azimuth, s.elevation, dist))
            .child(part("az", "az\u{a0}".into(), t.c.ink_secondary).a11y_hidden())
            .child(part("azv", a, t.c.ink).a11y_hidden())
            .child(part("s1", "\u{a0}·\u{a0}".into(), t.c.ink_secondary).a11y_hidden())
            .child(part("el", "el\u{a0}".into(), t.c.ink_secondary).a11y_hidden())
            .child(part("elv", e, t.c.ink).a11y_hidden())
            .child(part("s2", "\u{a0}·\u{a0}".into(), t.c.ink_secondary).a11y_hidden())
            .child(part("dv", d, t.c.ink).a11y_hidden())
    }
}
