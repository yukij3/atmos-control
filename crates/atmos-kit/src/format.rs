//! Mono readout formatting (audit L20/V14): zero shows as `0°` (never `+0°` or `-0°`), negatives
//! use U+2212 MINUS SIGN (as wide as `+` in SF Mono), and fixed-width fields keep a live readout
//! from jittering or reflowing.

/// U+2212 MINUS SIGN.
pub const MINUS: char = '\u{2212}';

/// Rounds to `decimals` places and drops the sign of a value that rounds to zero.
fn round_to(v: f32, decimals: u32) -> f32 {
    let k = 10f32.powi(decimals as i32);
    let r = (v * k).round() / k;
    if r == 0.0 { 0.0 } else { r }
}

/// Signed whole degrees: `+30°`, `0°`, `−20°`.
pub fn degrees(v: f32) -> String {
    let r = round_to(if v.is_finite() { v } else { 0.0 }, 0);
    if r > 0.0 {
        format!("+{r:.0}°")
    } else if r < 0.0 {
        format!("{MINUS}{:.0}°", -r)
    } else {
        "0°".to_owned()
    }
}

/// A distance in metres: two decimals below 1 m (`0.35 m`, the engine's minimum, stays exact),
/// one from 1 m (`1.0 m`, `6.0 m`).
pub fn metres(d: f32) -> String {
    let d = if d.is_finite() { d.max(0.0) } else { 0.0 };
    if round_to(d, 2) < 1.0 { format!("{d:.2} m") } else { format!("{d:.1} m") }
}

/// Linear amplitude (0…1, 1 = 0 dBFS) to dBFS; silence is `-inf`.
pub fn amplitude_db(linear: f32) -> f32 {
    if linear.is_finite() && linear > 0.0 { 20.0 * linear.log10() } else { f32::NEG_INFINITY }
}

/// A level in dB with one decimal: `−6.2 dB`, `0.0 dB`, `−∞ dB` for silence.
pub fn decibels(db: f32) -> String {
    if db == f32::NEG_INFINITY || db < -199.0 {
        return format!("{MINUS}∞ dB");
    }
    let r = round_to(db, 1);
    if r < 0.0 { format!("{MINUS}{:.1} dB", -r) } else if r > 0.0 { format!("+{r:.1} dB") } else { "0.0 dB".to_owned() }
}

/// A meter scale label: `0`, `−6`, `−60`.
pub fn db_tick(db: f32) -> String {
    let r = round_to(db, 0);
    if r < 0.0 { format!("{MINUS}{:.0}", -r) } else { format!("{r:.0}") }
}

/// U+00A0 NO-BREAK SPACE: padding that text layout never collapses or trims (SF Mono draws it
/// one digit wide, like every glyph).
pub const PAD: char = '\u{a0}';

/// Pads `s` on the left with no-break spaces to `width` characters (by `char`).
pub fn pad_left(s: &str, width: usize) -> String {
    let n = s.chars().count();
    if n >= width { s.to_owned() } else { format!("{}{s}", PAD.to_string().repeat(width - n)) }
}

/// Field widths of the readout line, in characters: the widest value each can show.
pub const AZIMUTH_FIELD: usize = 5; // −180°
pub const ELEVATION_FIELD: usize = 4; // +90°
pub const DISTANCE_FIELD: usize = 6; // 0.35 m

/// The readout's three values, each right-aligned in its fixed-width field. `distance: None` is
/// a far-field bed (distance inert), shown as `far`.
pub fn readout_fields(azimuth: f32, elevation: f32, distance: Option<f32>) -> [String; 3] {
    [
        pad_left(&degrees(azimuth), AZIMUTH_FIELD),
        pad_left(&degrees(elevation), ELEVATION_FIELD),
        pad_left(&distance.map_or_else(|| "far".to_owned(), metres), DISTANCE_FIELD),
    ]
}

/// The whole readout as one string, e.g. `az  +30° · el   0° ·  1.0 m`. Always the same number
/// of characters, so in a monospaced face it never changes width.
pub fn readout_line(azimuth: f32, elevation: f32, distance: Option<f32>) -> String {
    let [a, e, d] = readout_fields(azimuth, elevation, distance);
    format!("az {a} · el {e} · {d}")
}

/// Spoken description of a source position for assistive technology.
pub fn spoken_position(azimuth: f32, elevation: f32, distance: Option<f32>) -> String {
    let dist = distance.map_or_else(|| "far field".to_owned(), metres);
    format!("azimuth {}, elevation {}, distance {}", degrees(azimuth), degrees(elevation), dist)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signs_and_zero() {
        assert_eq!(degrees(30.0), "+30°");
        assert_eq!(degrees(0.0), "0°");
        assert_eq!(degrees(-0.3), "0°");
        assert_eq!(degrees(-0.0), "0°");
        assert_eq!(degrees(-20.0), "\u{2212}20°");
        assert_eq!(metres(1.0), "1.0 m");
        assert_eq!(metres(0.35), "0.35 m");
        assert_eq!(metres(0.999), "1.0 m");
        assert_eq!(decibels(-6.24), "\u{2212}6.2 dB");
        assert_eq!(decibels(amplitude_db(0.0)), "\u{2212}∞ dB");
        assert_eq!(db_tick(-12.0), "\u{2212}12");
        assert_eq!(db_tick(0.0), "0");
    }

    #[test]
    fn readout_width_is_constant() {
        let n = readout_line(0.0, 0.0, Some(1.0)).chars().count();
        for (a, e, d) in [(-180.0, -90.0, Some(0.35)), (30.0, 0.0, Some(1.0)), (5.0, 45.0, Some(6.0)), (-7.0, 9.0, None), (180.0, 90.0, Some(2.25))] {
            assert_eq!(readout_line(a, e, d).chars().count(), n, "{a} {e} {d:?}");
        }
        assert_eq!(readout_line(30.0, 0.0, Some(1.0)).replace(PAD, " "), "az  +30° · el   0° ·  1.0 m");
    }
}
