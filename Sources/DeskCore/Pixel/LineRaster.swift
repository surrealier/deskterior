/// Integer line rasterization (Bresenham-equivalent) for clock hands, the lamp arm and other 1-px strokes.
///
/// Lines are 8-connected with exactly `max(|dx|, |dy|) + 1` points: each pixel sits on the nearest row
/// (or column) to the ideal line, with ties broken the same way for every line. A segment is always
/// rasterized from a canonical endpoint, so `points(from: a, to: b) == points(from: b, to: a).reversed()`.
public enum LineRaster {
    /// Pixels of the segment `a`–`b`, both endpoints included, ordered from `a` to `b`.
    public static func points(from a: ArtPoint, to b: ArtPoint) -> [ArtPoint] {
        // Canonical direction: left to right; vertical lines top to bottom.
        let forward = a.x < b.x || (a.x == b.x && a.y <= b.y)
        let p = forward ? a : b, q = forward ? b : a
        let dx = q.x - p.x  // >= 0
        let dy = q.y - p.y
        let sy = dy < 0 ? -1 : 1
        let ady = abs(dy)
        var out: [ArtPoint] = []
        out.reserveCapacity(max(dx, ady) + 1)
        if dx >= ady {
            for i in 0...dx {
                out.append(ArtPoint(p.x + i, p.y + sy * roundedRatio(i * ady, dx)))
            }
        } else {
            for j in 0...ady {
                out.append(ArtPoint(p.x + roundedRatio(j * dx, ady), p.y + sy * j))
            }
        }
        if !forward { out.reverse() }
        return out
    }

    /// Joins consecutive segments through `vertices` without repeating the shared vertices.
    public static func polyline(_ vertices: [ArtPoint]) -> [ArtPoint] {
        guard let first = vertices.first else { return [] }
        var out = [first]
        for (a, b) in zip(vertices, vertices.dropFirst()) {
            out.append(contentsOf: points(from: a, to: b).dropFirst())
        }
        return out
    }

    /// Classic pixel-art cleanup ("pixel-perfect" strokes): drops every point that forms an L-shaped
    /// corner between two diagonal neighbours, and collapses consecutive duplicates. Endpoints are kept
    /// and an 8-connected path stays 8-connected.
    public static func pixelPerfect(_ pts: [ArtPoint]) -> [ArtPoint] {
        var path: [ArtPoint] = []
        path.reserveCapacity(pts.count)
        for p in pts where path.last != p { path.append(p) }
        guard path.count > 2 else { return path }
        var out: [ArtPoint] = [path[0]]
        for i in 1..<(path.count - 1) {
            let prev = out[out.count - 1], cur = path[i], next = path[i + 1]
            let lCorner = isOrthogonalNeighbour(prev, cur) && isOrthogonalNeighbour(next, cur)
                && prev.x != next.x && prev.y != next.y
            if !lCorner { out.append(cur) }
        }
        out.append(path[path.count - 1])
        return out
    }

    /// Draws the segment `a`–`b` into `buffer` (clipped).
    public static func draw(from a: ArtPoint, to b: ArtPoint, color: RGBA8, into buffer: inout PixelBuffer) {
        plot(points(from: a, to: b), color: color, into: &buffer)
    }

    /// Sets every point of `pts` in `buffer` (clipped).
    public static func plot(_ pts: [ArtPoint], color: RGBA8, into buffer: inout PixelBuffer) {
        for p in pts { buffer.set(p.x, p.y, color) }
    }

    private static func isOrthogonalNeighbour(_ a: ArtPoint, _ b: ArtPoint) -> Bool {
        abs(a.x - b.x) + abs(a.y - b.y) == 1
    }

    /// `round(n / d)` for `n >= 0, d > 0`, with exact halves rounded down.
    private static func roundedRatio(_ n: Int, _ d: Int) -> Int {
        d == 0 ? 0 : (2 * n + d - 1) / (2 * d)
    }
}
