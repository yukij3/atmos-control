//! The few line icons the UI needs, authored on a 16-unit grid in one stroke language (1.5
//! units, round caps and joins, `currentColor`), so they tint like text: `rune::icon(&RESET,
//! 14.0).color(t.c.ink_secondary)`. SF Symbols aren't reachable from Rune elements; these
//! follow their shapes (`exclamationmark.triangle`, `lock`, `arrow.counterclockwise`).

use rune::Icon;

/// A problem that blocks: permission denied, a missing driver, a failed start.
pub static WARNING: Icon = Icon {
    name: "atmos-warning",
    view: 16.0,
    body: r#"<path d="M6.9 2.7 Q8 0.9 9.1 2.7 L14.6 12.2 Q15.6 14 13.5 14 H2.5 Q0.4 14 1.4 12.2 Z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/><path d="M8 5.9 V9.1" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="8" cy="11.45" r="0.95" fill="currentColor"/>"#,
};

/// Privacy: audio-capture permission.
pub static LOCK: Icon = Icon {
    name: "atmos-lock",
    view: 16.0,
    body: r#"<rect x="3" y="7.1" width="10" height="7.4" rx="1.8" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M5.4 7.1 V5.1 A2.6 2.6 0 0 1 10.6 5.1 V7.1" fill="none" stroke="currentColor" stroke-width="1.4"/><circle cx="8" cy="10.8" r="1.05" fill="currentColor"/>"#,
};

/// Reset to defaults: a counter-clockwise arrow.
pub static RESET: Icon = Icon {
    name: "atmos-reset",
    view: 16.0,
    body: r#"<path d="M2.4 8.3 A5.6 5.6 0 1 0 8 2.7 A5.6 5.6 0 0 0 4.04 4.34 L2.4 6.2" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/><path d="M2.4 2.8 V6.2 H5.8" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>"#,
};
