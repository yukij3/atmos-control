//! Level meters: slim vertical bars on a −60…0 dB scale, a flat accent fill that turns orange
//! from −6 dB, a peak-hold line, and a red clip mark only when a peak reaches 0 dB. Two bars for
//! L/R in the panel, twelve for the 7.1.4 view in settings.

use std::borrow::Cow;

use rune::{Align, El, col, el, row, text};

use crate::format;
use crate::stage::{ATMOS_714_LABELS, range};
use crate::theme::{Theme, ty};

/// Where the dB scale sits.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ScaleSide {
    /// Left of the bars.
    Leading,
    /// Right of the bars (the panel default: the bars, not the labels, face the elevation gauge).
    #[default]
    Trailing,
}

/// One channel's levels, linear amplitude (0…1, 1 = 0 dBFS), as the snapshot gives them.
#[derive(Clone, Debug, PartialEq)]
pub struct MeterChannel {
    pub label: Cow<'static, str>,
    /// Current (already smoothed) level.
    pub level: f32,
    /// Peak hold, when the engine keeps one.
    pub peak_hold: Option<f32>,
}

impl MeterChannel {
    pub fn new(label: impl Into<Cow<'static, str>>, level: f32, peak_hold: Option<f32>) -> MeterChannel {
        MeterChannel { label: label.into(), level, peak_hold }
    }
}

/// dB scale marks.
const TICKS: [f32; 7] = [0.0, -6.0, -12.0, -24.0, -36.0, -48.0, -60.0];
/// From here up the fill is orange.
pub const WARN_DB: f32 = -6.0;
/// A peak at or above this is a clip (0 dBFS, with float slack).
pub const CLIP_DB: f32 = -0.01;

/// Level meters.
pub struct Meters {
    channels: Vec<MeterChannel>,
    height: f32,
    bar: f32,
    column: f32,
    scale: ScaleSide,
    active: bool,
    key: &'static str,
    label: &'static str,
}

impl Meters {
    /// Twin L/R bars from the snapshot's `meter_l`, `meter_r`, `peak_hold_l`, `peak_hold_r`.
    pub fn stereo(level_l: f32, level_r: f32, hold_l: f32, hold_r: f32) -> Meters {
        Meters::new(vec![MeterChannel::new("L", level_l, Some(hold_l)), MeterChannel::new("R", level_r, Some(hold_r))])
            .label("Output levels")
    }

    /// The 12-channel 7.1.4 view from `channel_peaks` (Atmos order L R C LFE Ls Rs Rls Rrs Vhl
    /// Vhr Ltr Rtr). Other lengths are numbered.
    pub fn surround(peaks: &[f32]) -> Meters {
        let channels = peaks
            .iter()
            .enumerate()
            .map(|(i, &p)| {
                let label: Cow<'static, str> =
                    if peaks.len() == 12 { Cow::Borrowed(ATMOS_714_LABELS[i]) } else { Cow::Owned((i + 1).to_string()) };
                MeterChannel { label, level: p, peak_hold: None }
            })
            .collect();
        Meters::new(channels).bar_width(6.0).column(20.0).scale_side(ScaleSide::Leading).label("Surround channel levels")
    }

    pub fn new(channels: Vec<MeterChannel>) -> Meters {
        Meters {
            channels,
            height: 190.0,
            bar: 6.0,
            column: 10.0,
            scale: ScaleSide::Trailing,
            active: true,
            key: "meters",
            label: "Levels",
        }
    }
    /// Total height, channel labels included (default 190 pt, the compact radar's).
    pub fn height(mut self, h: f32) -> Self {
        self.height = h.max(60.0);
        self
    }
    pub fn bar_width(mut self, w: f32) -> Self {
        self.bar = w.max(2.0);
        self
    }
    /// Width given to each channel (bar + its share of the gap, or its label if wider).
    pub fn column(mut self, w: f32) -> Self {
        self.column = w;
        self
    }
    pub fn scale_side(mut self, side: ScaleSide) -> Self {
        self.scale = side;
        self
    }
    /// Engine rendering (snapshot `is_on`); off draws empty tracks.
    pub fn active(mut self, on: bool) -> Self {
        self.active = on;
        self
    }
    pub fn key(mut self, key: &'static str) -> Self {
        self.key = key;
        self
    }
    /// Accessible name of the group.
    pub fn label(mut self, label: &'static str) -> Self {
        self.label = label;
        self
    }

    pub fn build(self, t: &Theme) -> El {
        let Meters { channels, height, bar, column, scale, active, key, label } = self;
        let column = column.max(bar + 4.0);
        // Vertical layout: clip mark, gap, track (0 dB at its top, −60 at its bottom), labels.
        let clip_h = 3.0;
        let track_top = clip_h + 3.0;
        let label_h = 14.0;
        let track_h = height - track_top - label_h - 2.0;
        let y_of = |db: f32| track_top + (-db.clamp(range::METER_DB.0, 0.0) / -range::METER_DB.0) * track_h;

        let bars = channels.iter().enumerate().map(|(i, ch)| {
            let level_db = if active { format::amplitude_db(ch.level) } else { f32::NEG_INFINITY };
            let hold_db = if active { ch.peak_hold.map(format::amplitude_db) } else { None };
            let clipped = hold_db.unwrap_or(level_db) >= CLIP_DB || level_db >= CLIP_DB;
            let x = (column - bar) / 2.0;
            // The fill is always there (zero high in silence) so it can ease between snapshots.
            let fill_top = if level_db > range::METER_DB.0 { y_of(level_db) } else { track_top + track_h };
            let fill = |key: &'static str, color| {
                el().key(key)
                    .absolute(x, fill_top)
                    .size(bar, track_top + track_h - fill_top)
                    .fill(color)
                    .frame_motion(t.motion.meter)
            };
            let mut colm = el()
                .key(CHANNEL_KEYS[i.min(CHANNEL_KEYS.len() - 1)])
                .size(column, height)
                .role("meter")
                .label(channel_name(&ch.label))
                .range_value(level_db.max(range::METER_DB.0) as f64, range::METER_DB.0 as f64, 0.0)
                .a11y_value(if active { format::decibels(level_db) } else { "Engine off".to_owned() })
                // Track.
                .child(el().key("track").absolute(x, track_top).size(bar, track_h).fill(t.c.track))
                // Accent fill from the floor to the level.
                .child(fill("fill", t.c.accent))
                // The same fill in orange, seen only through a window over −6…0 dB, so the two
                // move as one bar.
                .child(
                    el().key("warnzone")
                        .absolute(0.0, 0.0)
                        .size(column, y_of(WARN_DB))
                        .clip_soft(0.0)
                        .child(fill("warn", t.c.warn)),
                )
                ;
            // Clip mark above the track, only after a 0 dB peak.
            if clipped {
                colm = colm.child(el().key("clip").absolute(x, 0.0).size(bar, clip_h).fill(t.c.clip));
            }
            if let Some(h) = hold_db.filter(|h| *h > range::METER_DB.0) {
                let color = if h >= CLIP_DB {
                    t.c.clip
                } else if h >= WARN_DB {
                    t.c.warn
                } else {
                    t.c.accent
                };
                let thick = if h >= CLIP_DB { 2.0 } else { 1.5 };
                colm = colm.child(
                    el().key("hold").absolute(x, y_of(h) - thick / 2.0).size(bar, thick).fill(color).frame_motion(t.motion.meter),
                );
            }
            colm.child(
                text(ch.label.clone())
                    .key("name")
                    .font(ty::TICK)
                    .color(t.c.ink_secondary)
                    .align(Align::Center)
                    .absolute(0.0, height - label_h + 2.0)
                    .size(column, 11.0)
                    .a11y_hidden(),
            )
        });
        let bars = row().key("bars").children(bars);

        // Scale: labels only, 4 pt off the bars, centred on their level (a tick mark before
        // a minus sign would read as a double dash).
        let scale_w = 24.0;
        let mut scale_el = el().key("scale").size(scale_w, height).a11y_hidden();
        for &db in &TICKS {
            let (x, align) = match scale { ScaleSide::Trailing => (2.0, Align::Start), ScaleSide::Leading => (0.0, Align::End) };
            scale_el = scale_el.child(
                text(format::db_tick(db))
                    .font(ty::TICK)
                    .color(t.c.ink_secondary)
                    .align(align)
                    .absolute(x, y_of(db) - 5.5)
                    .size(scale_w - 2.0, 11.0),
            );
        }

        let body = match scale {
            ScaleSide::Trailing => row().child(bars).child(scale_el),
            ScaleSide::Leading => row().child(scale_el).child(bars),
        };
        col().key(key).role("group").label(label).child(body)
    }
}

const CHANNEL_KEYS: [&str; 16] =
    ["ch0", "ch1", "ch2", "ch3", "ch4", "ch5", "ch6", "ch7", "ch8", "ch9", "ch10", "ch11", "ch12", "ch13", "ch14", "ch15"];

fn channel_name(label: &str) -> String {
    let name = match label {
        "L" => "Left",
        "R" => "Right",
        "C" => "Centre",
        "LFE" => "LFE",
        "Ls" => "Left surround",
        "Rs" => "Right surround",
        "Rls" => "Left rear surround",
        "Rrs" => "Right rear surround",
        "Vhl" => "Left front height",
        "Vhr" => "Right front height",
        "Ltr" => "Left rear height",
        "Rtr" => "Right rear height",
        other => return format!("Channel {other} level"),
    };
    format!("{name} level")
}
