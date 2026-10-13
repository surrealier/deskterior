import Foundation

/// RGB → nearest Apollo index table for the GPU lit pass (DESIGN §1.1).
///
/// **Layout.** 64³ = 262,144 bytes, one palette index (0…45) per bin. A colour falls in bin
/// `(r6, g6, b6) = (r >> 2, g >> 2, b >> 2)` and its byte offset is `(b6 * 64 + g6) * 64 + r6`.
/// Upload as a 3D `.r8Uint` texture with width = r, height = g, depth = b (64 each),
/// `bytesPerRow` 64 and `bytesPerImage` 4096; the shader reads `lut.read(uint3(rgb8 >> 2))`.
///
/// **Contents** (first rule that applies wins):
/// 1. a bin holding an exact Apollo colour stores that colour (no two Apollo colours share a bin; the
///    closest pair, `172038`/`1e1d39`, is 7.7 RGB units apart);
/// 2. a bin reachable from exactly one Apollo colour by a ±1 drift per channel stores that colour, so
///    the off-by-one values SpriteKit's blending can produce snap back even across a bin edge;
/// 3. otherwise the OKLab-nearest Apollo colour to the bin centre `(v * 4 + 1.5)` per channel.
public struct IndexLUT: Sendable {
    /// Bins per channel.
    public static let side = 64
    /// Total table size in bytes (`side³`).
    public static let byteCount = side * side * side

    /// The table, built on first use (about 0.1 s in a debug build, 15 ms optimized). Call `prewarm()` at
    /// launch so the first frame does not pay for it on the main thread.
    public static let shared = IndexLUT()

    /// Builds `shared` on a background queue. Safe to call more than once; a later `shared` access waits
    /// for the build in progress instead of starting another.
    public static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async { _ = IndexLUT.shared }
    }

    /// `byteCount` palette indices in the layout documented on the type.
    public let bytes: [UInt8]

    /// Builds a fresh table; use `shared`.
    init() {
        bytes = IndexLUT.build()
    }

    /// Byte offset of the bin containing `c` (alpha ignored).
    @inlinable
    public static func offset(of c: RGBA8) -> Int {
        offset(r6: Int(c.r >> 2), g6: Int(c.g >> 2), b6: Int(c.b >> 2))
    }

    /// Byte offset of bin `(r6, g6, b6)`, each 0..<64.
    @inlinable
    public static func offset(r6: Int, g6: Int, b6: Int) -> Int {
        (b6 * side + g6) * side + r6
    }

    /// Palette index for `c` (alpha ignored).
    @inlinable
    public func lookup(_ c: RGBA8) -> Int {
        Int(bytes[IndexLUT.offset(of: c)])
    }

    static func build() -> [UInt8] {
        var table = [UInt8](repeating: 0, count: byteCount)
        table.withUnsafeMutableBufferPointer { nearestToBinCentres(into: $0) }

        // Rule 2: bins claimed by exactly one palette colour's ±1 drift (-2 marks a contested bin).
        var claims: [Int: Int] = [:]
        for (i, c) in Apollo.colors.enumerated() {
            for dr in -1...1 {
                for dg in -1...1 {
                    for db in -1...1 {
                        let o = offset(of: RGBA8(drift(c.r, dr), drift(c.g, dg), drift(c.b, db)))
                        if let prev = claims[o], prev != i { claims[o] = -2 } else { claims[o] = i }
                    }
                }
            }
        }
        for (o, i) in claims where i >= 0 { table[o] = UInt8(i) }

        // Rule 1: exact colours.
        for (i, c) in Apollo.colors.enumerated() { table[offset(of: c)] = UInt8(i) }
        return table
    }

    /// Rule 3: the OKLab-nearest palette index to every bin centre, exactly as `Apollo.nearestIndex` finds it
    /// (same distances, ties to the lowest index), without testing all 46 colours per bin:
    /// - the palette is scanned in lightness order outward from the bin's L, stopping once ΔL² alone exceeds
    ///   the second-best distance;
    /// - along a row, a bin within `(d₂ − d₁) / 2` of the last fully searched centre (d₁, d₂: its two nearest
    ///   distances) has the same nearest colour by the triangle inequality, so it needs no search.
    private static func nearestToBinCentres(into out: UnsafeMutableBufferPointer<UInt8>) {
        let n = Apollo.count
        let order = (0..<n).sorted { Apollo.oklab[$0].L < Apollo.oklab[$1].L }
        let sorted = order.flatMap { [Apollo.oklab[$0].L, Apollo.oklab[$0].a, Apollo.oklab[$0].b] }
        let centre = (0..<side).map { OKLab.srgbToLinear((Double($0) * 4 + 1.5) / 255) }
        sorted.withUnsafeBufferPointer { p in
            order.withUnsafeBufferPointer { order in
                var o = 0
                var pos = 0                                   // first sorted entry lighter than the current L
                for b6 in 0..<side {
                    for g6 in 0..<side {
                        var anchor = OKLab(L: 0, a: 0, b: 0)
                        var best = 0
                        var margin = -1.0                     // (d₂ − d₁) / 2 at `anchor`; ≤ 0 forces a search
                        for r6 in 0..<side {
                            let lab = OKLab(linearR: centre[r6], g: centre[g6], b: centre[b6])
                            if margin > 0 && lab.distance(to: anchor) + 1e-9 < margin {
                                out[o] = UInt8(best)
                                o += 1
                                continue
                            }
                            while pos > 0 && p[3 * (pos - 1)] > lab.L { pos -= 1 }
                            while pos < n && p[3 * pos] <= lab.L { pos += 1 }
                            var near = Nearest()
                            var k = pos - 1
                            while k >= 0, square(lab.L - p[3 * k]) <= near.d2 {
                                near.consider(order[k], lab, p[3 * k], p[3 * k + 1], p[3 * k + 2])
                                k -= 1
                            }
                            k = pos
                            while k < n, square(p[3 * k] - lab.L) <= near.d2 {
                                near.consider(order[k], lab, p[3 * k], p[3 * k + 1], p[3 * k + 2])
                                k += 1
                            }
                            best = near.i1
                            anchor = lab
                            margin = (near.d2.squareRoot() - near.d1.squareRoot()) / 2
                            out[o] = UInt8(best)
                            o += 1
                        }
                    }
                }
            }
        }
    }

    /// The nearest palette index so far (ties to the lowest index) and the two smallest squared distances.
    private struct Nearest {
        var i1 = -1
        var d1 = Double.infinity
        var d2 = Double.infinity

        mutating func consider(_ i: Int, _ lab: OKLab, _ L: Double, _ a: Double, _ b: Double) {
            let dL = lab.L - L, da = lab.a - a, db = lab.b - b
            let d = dL * dL + da * da + db * db
            if d < d1 || (d == d1 && i < i1) {
                d2 = d1
                (i1, d1) = (i, d)
            } else if d < d2 {
                d2 = d
            }
        }
    }

    private static func square(_ v: Double) -> Double { v * v }

    private static func drift(_ v: UInt8, _ d: Int) -> UInt8 {
        UInt8(min(max(Int(v) + d, 0), 255))
    }
}
