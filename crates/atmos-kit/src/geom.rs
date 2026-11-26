//! Polygon helpers. Curved marks are filled polygons, not translucent polylines: Rune blends a
//! translucent stroke twice where segments meet, which would bead a thin arc.

use rune::Path;

/// Adds an axis-aligned ellipse to `path` as its own closed subpath of four cubic Béziers,
/// clockwise on screen (right, bottom, left, top), so parts drawn with it and filled non-zero
/// merge into one silhouette. Rune flattens the curves to 0.1 pt: smooth at any size or turn.
pub fn ellipse_path(path: Path, cx: f32, cy: f32, rx: f32, ry: f32) -> Path {
    // The control-point distance that makes a quarter circle out of one cubic.
    const K: f32 = 0.552_284_8;
    let (kx, ky) = (rx * K, ry * K);
    path.move_to([cx + rx, cy])
        .cubic_to([cx + rx, cy + ky], [cx + kx, cy + ry], [cx, cy + ry])
        .cubic_to([cx - kx, cy + ry], [cx - rx, cy + ky], [cx - rx, cy])
        .cubic_to([cx - rx, cy - ky], [cx - kx, cy - ry], [cx, cy - ry])
        .cubic_to([cx + kx, cy - ry], [cx + rx, cy - ky], [cx + rx, cy])
        .close()
}

/// The outline of an open polyline `width` wide with mitred joints and butt ends, as one simple
/// polygon (for a chevron that stays one even weight when it turns).
pub fn thick_polyline(points: &[[f32; 2]], width: f32) -> Vec<[f32; 2]> {
    let n = points.len();
    if n < 2 {
        return Vec::new();
    }
    let h = width / 2.0;
    let normal = |a: [f32; 2], b: [f32; 2]| {
        let (dx, dy) = (b[0] - a[0], b[1] - a[1]);
        let len = dx.hypot(dy).max(1e-6);
        [-dy / len, dx / len]
    };
    let offsets: Vec<[f32; 2]> = (0..n)
        .map(|i| {
            if i == 0 {
                normal(points[0], points[1])
            } else if i == n - 1 {
                normal(points[n - 2], points[n - 1])
            } else {
                let (n1, n2) = (normal(points[i - 1], points[i]), normal(points[i], points[i + 1]));
                let m = [n1[0] + n2[0], n1[1] + n2[1]];
                let len = m[0].hypot(m[1]).max(1e-6);
                let m = [m[0] / len, m[1] / len];
                // Miter length, capped so a sharp turn doesn't spike.
                let k = 1.0 / (m[0] * n1[0] + m[1] * n1[1]).max(0.25);
                [m[0] * k, m[1] * k]
            }
        })
        .collect();
    let left = points.iter().zip(&offsets).map(|(p, o)| [p[0] + o[0] * h, p[1] + o[1] * h]);
    let right: Vec<[f32; 2]> = points.iter().zip(&offsets).map(|(p, o)| [p[0] - o[0] * h, p[1] - o[1] * h]).collect();
    left.chain(right.into_iter().rev()).collect()
}

/// A point at `radius` and `angle` (radians, clockwise from 12 o'clock) around `(cx, cy)`.
pub fn polar(cx: f32, cy: f32, radius: f32, angle: f32) -> [f32; 2] {
    [cx + radius * angle.sin(), cy - radius * angle.cos()]
}

/// A thin annular band between `r_in` and `r_out` from angle `a0` to `a1` (radians, clockwise
/// from 12 o'clock), as one simple polygon.
pub fn arc_band(cx: f32, cy: f32, r_in: f32, r_out: f32, a0: f32, a1: f32) -> Vec<[f32; 2]> {
    let span = (a1 - a0).abs();
    let steps = ((span.to_degrees() / 3.0).ceil() as usize).max(2);
    let outer = (0..=steps).map(|i| polar(cx, cy, r_out, a0 + (a1 - a0) * i as f32 / steps as f32));
    let inner = (0..=steps).rev().map(|i| polar(cx, cy, r_in, a0 + (a1 - a0) * i as f32 / steps as f32));
    outer.chain(inner).collect()
}
