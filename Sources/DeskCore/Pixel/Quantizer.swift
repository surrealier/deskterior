/// Pure pixelation steps for icons, thumbnails and wallpaper (DESIGN §3.4). A typical icon chain is
/// `trimToOpaque` → `areaAverage` → `thresholdAlpha` → `mapToPalette` → `removeOrphans` → `outline`.
///
/// "Opaque" means alpha ≠ 0 throughout, matching `PixelBuffer.opaqueBounds()`.
public enum Quantizer {
    /// Box-filter downsample (or upsample) to `size`. Each output pixel averages the source pixels it
    /// covers, weighted by exact fractional coverage (non-integer ratios included). Colour is averaged in
    /// sRGB-encoded space weighted by alpha; the result has straight, non-binary alpha (binarize it with
    /// `thresholdAlpha`), and a pixel whose alpha rounds to 0 is `.clear`.
    public static func areaAverage(_ src: PixelBuffer, to size: ArtSize) -> PixelBuffer {
        precondition(size.w >= 0 && size.h >= 0, "negative target size \(size)")
        var out = PixelBuffer(width: size.w, height: size.h)
        guard size.area > 0, src.width > 0, src.height > 0 else { return out }
        let xs = coverage(source: src.width, target: size.w)
        let ys = coverage(source: src.height, target: size.h)
        // Weights along x sum to src.width and along y to src.height, so every output pixel's total
        // weight is src.width * src.height. Integer sums keep uniform inputs exact.
        let total = src.width * src.height
        for dy in 0..<size.h {
            for dx in 0..<size.w {
                var sa = 0, sr = 0, sg = 0, sb = 0
                for (sy, wy) in ys[dy] {
                    let row = sy * src.width
                    for (sx, wx) in xs[dx] {
                        let c = src.pixels[row + sx]
                        if c.a == 0 { continue }
                        let w = wx * wy * Int(c.a)
                        sa += w
                        sr += w * Int(c.r)
                        sg += w * Int(c.g)
                        sb += w * Int(c.b)
                    }
                }
                let a = (sa + total / 2) / total
                guard a > 0 else { continue }
                out.pixels[dy * size.w + dx] = RGBA8(
                    UInt8((sr + sa / 2) / sa), UInt8((sg + sa / 2) / sa), UInt8((sb + sa / 2) / sa), UInt8(a)
                )
            }
        }
        return out
    }

    /// Binarizes alpha: pixels with alpha ≥ `threshold` (0…1) become opaque with their colour, all
    /// others `.clear`. Fully transparent pixels always stay clear.
    public static func thresholdAlpha(_ b: PixelBuffer, at threshold: Double = 0.45) -> PixelBuffer {
        let cut = threshold * 255
        var out = b
        for (i, c) in b.pixels.enumerated() {
            out.pixels[i] = c.a != 0 && Double(c.a) >= cut ? RGBA8(c.r, c.g, c.b, 255) : .clear
        }
        return out
    }

    /// Snaps every opaque pixel to the OKLab-nearest palette colour among `allowed` (default: all of
    /// Apollo); the output is opaque Apollo colours plus `.clear`. With `dither`, a 4×4 ordered Bayer
    /// dither picks between the two nearest allowed colours: the second one wins where the pixel's
    /// relative distance `d0 / (d0 + d1)` (0…0.5) exceeds the Bayer threshold at `(x, y)`.
    public static func mapToPalette(_ b: PixelBuffer, allowed: [Int]? = nil, dither: Bool = false) -> PixelBuffer {
        var out = PixelBuffer(width: b.width, height: b.height)
        var cache: [UInt32: (near: Int, far: Int, t: Double)] = [:]
        for y in 0..<b.height {
            for x in 0..<b.width {
                let c = b.pixels[y * b.width + x]
                guard c.a != 0 else { continue }
                let choice: (near: Int, far: Int, t: Double)
                if let hit = cache[c.rgbHex] {
                    choice = hit
                } else {
                    choice = nearestPair(c, allowed: allowed)
                    cache[c.rgbHex] = choice
                }
                let useFar = dither && choice.t > (Double(bayer4[(y & 3) * 4 + (x & 3)]) + 0.5) / 16
                out.pixels[y * b.width + x] = Apollo.colors[useFar ? choice.far : choice.near]
            }
        }
        return out
    }

    /// Median cut in OKLab over the opaque pixels: splits the box with the largest (pixel count × longest
    /// axis range) at its weighted median until there are `maxColors` boxes or none can split, then snaps
    /// each box mean to the nearest Apollo index. Returns the distinct indices, ascending (≤ `maxColors`;
    /// empty when there are no opaque pixels).
    public static func medianCut(_ b: PixelBuffer, maxColors: Int) -> [Int] {
        guard maxColors > 0 else { return [] }
        var counts: [UInt32: Int] = [:]
        for c in b.pixels where c.a != 0 { counts[c.rgbHex, default: 0] += 1 }
        guard !counts.isEmpty else { return [] }

        typealias Entry = (rgb: UInt32, lab: SIMD3<Double>, n: Int)
        let entries: [Entry] = counts.keys.sorted().map { key in
            let lab = OKLab(RGBA8(hex: key))
            return (key, SIMD3(lab.L, lab.a, lab.b), counts[key]!)
        }
        var boxes: [[Entry]] = [entries]

        func longestAxis(_ box: [Entry]) -> (axis: Int, range: Double) {
            var best = (axis: 0, range: 0.0)
            for axis in 0..<3 {
                var lo = Double.infinity, hi = -Double.infinity
                for e in box {
                    lo = min(lo, e.lab[axis])
                    hi = max(hi, e.lab[axis])
                }
                if hi - lo > best.range { best = (axis, hi - lo) }
            }
            return best
        }

        while boxes.count < maxColors {
            var pick: (box: Int, axis: Int, score: Double)?
            for (i, box) in boxes.enumerated() where box.count > 1 {
                let (axis, range) = longestAxis(box)
                let score = range * Double(box.reduce(0) { $0 + $1.n })
                if score > (pick?.score ?? 0) { pick = (i, axis, score) }
            }
            guard let pick else { break }
            let sorted = boxes[pick.box].sorted {
                $0.lab[pick.axis] != $1.lab[pick.axis] ? $0.lab[pick.axis] < $1.lab[pick.axis] : $0.rgb < $1.rgb
            }
            let total = sorted.reduce(0) { $0 + $1.n }
            var k = 0, acc = 0
            repeat {
                acc += sorted[k].n
                k += 1
            } while k < sorted.count - 1 && acc * 2 < total
            boxes[pick.box] = Array(sorted[..<k])
            boxes.append(Array(sorted[k...]))
        }

        var result = Set<Int>()
        for box in boxes {
            var sum = SIMD3<Double>(), n = 0.0
            for e in box {
                sum += e.lab * Double(e.n)
                n += Double(e.n)
            }
            let mean = sum / n
            result.insert(Apollo.nearestIndex(to: OKLab(L: mean.x, a: mean.y, b: mean.z)))
        }
        return result.sorted()
    }

    /// Clears opaque pixels that have no opaque 8-neighbour. Diagonal neighbours count, so 1-px diagonal
    /// strokes (ticks, arrows, pen nibs) survive; only isolated specks go.
    public static func removeOrphans(_ b: PixelBuffer) -> PixelBuffer {
        var out = b
        for y in 0..<b.height {
            for x in 0..<b.width where b.pixels[y * b.width + x].a != 0 {
                if !hasOpaqueNeighbour(b, x, y, diagonals: true) { out.pixels[y * b.width + x] = .clear }
            }
        }
        return out
    }

    /// Paints `color` on every transparent pixel 4-adjacent to an opaque one. The size is unchanged, so
    /// callers leave a 1-px transparent margin for the ring.
    public static func outline(_ b: PixelBuffer, color: RGBA8) -> PixelBuffer {
        var out = b
        for y in 0..<b.height {
            for x in 0..<b.width where b.pixels[y * b.width + x].a == 0 {
                if hasOpaqueNeighbour(b, x, y, diagonals: false) { out.pixels[y * b.width + x] = color }
            }
        }
        return out
    }

    /// Crops to the opaque bounding box (0×0 when nothing is opaque).
    public static func trimToOpaque(_ b: PixelBuffer) -> PixelBuffer {
        b.cropped(to: b.opaqueBounds())
    }

    // MARK: Private

    /// Standard 4×4 Bayer matrix, row-major; threshold = (value + 0.5) / 16.
    private static let bayer4: [UInt8] = [
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5,
    ]

    /// For each target cell along one axis, the source cells it overlaps and the overlap length, in units
    /// where a source cell is `target` long and a target cell is `source` long.
    private static func coverage(source: Int, target: Int) -> [[(index: Int, weight: Int)]] {
        (0..<target).map { d in
            let lo = d * source, hi = (d + 1) * source
            var cells: [(index: Int, weight: Int)] = []
            var s = lo / target
            while s * target < hi {
                let w = min(hi, (s + 1) * target) - max(lo, s * target)
                if w > 0 { cells.append((s, w)) }
                s += 1
            }
            return cells
        }
    }

    private static func nearestPair(_ c: RGBA8, allowed: [Int]?) -> (near: Int, far: Int, t: Double) {
        let n = Apollo.nearestTwo(to: OKLab(c), among: allowed)
        let d0 = n.d0.squareRoot(), d1 = n.d1.squareRoot()
        let t = d0 + d1 > 0 ? d0 / (d0 + d1) : 0
        return (n.first, n.second, t)
    }

    /// Whether a 4-neighbour (or, with `diagonals`, an 8-neighbour) of `(x, y)` is opaque.
    private static func hasOpaqueNeighbour(_ b: PixelBuffer, _ x: Int, _ y: Int, diagonals: Bool) -> Bool {
        if b.pixel(x - 1, y).a != 0 || b.pixel(x + 1, y).a != 0 || b.pixel(x, y - 1).a != 0 || b.pixel(x, y + 1).a != 0 {
            return true
        }
        return diagonals && (b.pixel(x - 1, y - 1).a != 0 || b.pixel(x + 1, y - 1).a != 0
            || b.pixel(x - 1, y + 1).a != 0 || b.pixel(x + 1, y + 1).a != 0)
    }
}
