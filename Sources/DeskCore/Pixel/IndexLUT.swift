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

    /// The table, built on first use.
    public static let shared = IndexLUT()

    /// `byteCount` palette indices in the layout documented on the type.
    public let bytes: [UInt8]

    public init() {
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

    private static func build() -> [UInt8] {
        // Rule 3: nearest to each bin centre (a flat search; same result as Apollo.nearestIndex, ties to
        // the lowest index).
        let centreLinear = (0..<side).map { OKLab.srgbToLinear((Double($0) * 4 + 1.5) / 255) }
        let palette = Apollo.oklab.flatMap { [$0.L, $0.a, $0.b] }
        var table = [UInt8](repeating: 0, count: byteCount)
        palette.withUnsafeBufferPointer { p in
            table.withUnsafeMutableBufferPointer { out in
                var o = 0
                for b6 in 0..<side {
                    for g6 in 0..<side {
                        for r6 in 0..<side {
                            let lab = OKLab(linearR: centreLinear[r6], g: centreLinear[g6], b: centreLinear[b6])
                            var best = 0, bestD = Double.infinity
                            for i in 0..<Apollo.count {
                                let dL = lab.L - p[i * 3], da = lab.a - p[i * 3 + 1], db = lab.b - p[i * 3 + 2]
                                let d = dL * dL + da * da + db * db
                                if d < bestD { (best, bestD) = (i, d) }
                            }
                            out[o] = UInt8(best)
                            o += 1
                        }
                    }
                }
            }
        }

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

    private static func drift(_ v: UInt8, _ d: Int) -> UInt8 {
        UInt8(min(max(Int(v) + d, 0), 255))
    }
}
