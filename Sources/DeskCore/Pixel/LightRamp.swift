import Foundation

/// The hue a dimmed pixel drifts toward: moonlight / outdoor light (`cool`, toward `253a5e`) or
/// lamplight (`warm`, toward `de9e41`).
public enum Tint: Int, Sendable, CaseIterable {
    case cool, warm
}

/// Precomputed relighting table (DESIGN §1.4): palette index × light level 0…7 × tint → palette index.
///
/// Level 7 is the identity. Lower levels compress OKLab lightness toward the palette's floor, fade
/// chroma, and blend a/b toward the tint's hue with a weight that grows as the level drops; the target
/// is snapped to Apollo (OKLab, chroma weighted ×2 so hue families survive). Each `(index, tint)` column
/// is then made monotonic: a level is never lighter than the level above it.
public struct LightRamp: Sendable {
    /// Number of light levels (0…7).
    public static let levelCount = 8
    /// The identity level.
    public static let maxLevel = 7

    /// The table, built on first use.
    public static let shared = LightRamp()

    /// Flattened table, one palette index per byte at offset `((tint * 8) + level) * 46 + index`.
    /// Upload as a 2D `.r8Uint` texture of width 46 (index) × height 16 (row `tint * 8 + level`),
    /// `bytesPerRow` 46; the lit pass reads `ramp.read(uint2(index, tint * 8 + level))`.
    public let gpuBytes: [UInt8]

    public init() {
        gpuBytes = LightRamp.build()
    }

    /// Byte offset of an entry in `gpuBytes`.
    @inlinable
    public static func offset(index: Int, level: Int, tint: Tint) -> Int {
        (tint.rawValue * levelCount + level) * Apollo.count + index
    }

    /// The palette index that `index` becomes at `level` under `tint`.
    public func map(_ index: Int, level: Int, tint: Tint) -> Int {
        precondition(index >= 0 && index < Apollo.count, "palette index out of range: \(index)")
        precondition(level >= 0 && level <= LightRamp.maxLevel, "light level out of range: \(level)")
        return Int(gpuBytes[LightRamp.offset(index: index, level: level, tint: tint)])
    }

    /// Relights an opaque Apollo colour; any other colour (including `.clear`) passes through unchanged.
    public func mapColor(_ c: RGBA8, level: Int, tint: Tint) -> RGBA8 {
        guard let i = Apollo.index(of: c) else { return c }
        return Apollo.colors[map(i, level: level, tint: tint)]
    }

    /// `gpuBytes` expanded to RGBA8 colours (4 bytes per entry, same order), for a lit pass that wants
    /// colours instead of indices: a 46 × 16 `.rgba8Unorm` texture with `bytesPerRow` 184.
    public var gpuRGBABytes: [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(gpuBytes.count * 4)
        for i in gpuBytes {
            let c = Apollo.colors[Int(i)]
            out.append(contentsOf: [c.r, c.g, c.b, c.a])
        }
        return out
    }

    // MARK: Tuning

    /// Lightness scale per level: 0.12 at level 0 rising to 1 at level 7.
    public static func lightnessScale(level: Int) -> Double {
        0.12 + 0.88 * pow(Double(level) / Double(maxLevel), 0.9)
    }

    /// Lightness that darkening converges to (just below Apollo's darkest, `090a14` at L ≈ 0.149).
    private static let lightnessFloor = 0.13
    /// Chroma fades as (newL / oldL)^chromaExponent.
    private static let chromaExponent = 0.6
    /// Tint blend weight falls as (1 - level/7)^tintExponent from its level-0 value.
    private static let tintExponent = 1.5
    /// Weight of a/b against L when snapping, so a dimmed colour prefers its own hue family.
    private static let chromaSnapWeight = 2.0
    private static let coolHue = OKLab(RGBA8(hex: 0x253a5e))
    private static let warmHue = OKLab(RGBA8(hex: 0xde9e41))

    private static func target(_ lab: OKLab, level: Int, tint: Tint) -> OKLab {
        let L = lab.L > lightnessFloor
            ? lightnessFloor + (lab.L - lightnessFloor) * lightnessScale(level: level)
            : lab.L
        let fade = lab.L > 0 ? pow(L / lab.L, chromaExponent) : 1
        let (hue, maxWeight) = tint == .cool ? (coolHue, 0.9) : (warmHue, 0.6)
        let w = maxWeight * pow(1 - Double(level) / Double(maxLevel), tintExponent)
        return OKLab(
            L: L,
            a: lab.a * fade * (1 - w) + hue.a * w,
            b: lab.b * fade * (1 - w) + hue.b * w
        )
    }

    private static func snap(_ t: OKLab) -> Int {
        var best = 0, bestD = Double.infinity
        for (i, p) in Apollo.oklab.enumerated() {
            let dL = t.L - p.L, da = t.a - p.a, db = t.b - p.b
            let d = dL * dL + chromaSnapWeight * (da * da + db * db)
            if d < bestD { (best, bestD) = (i, d) }
        }
        return best
    }

    private static func build() -> [UInt8] {
        var table = [UInt8](repeating: 0, count: Tint.allCases.count * levelCount * Apollo.count)
        for tint in Tint.allCases {
            for index in 0..<Apollo.count {
                var above = index
                table[offset(index: index, level: maxLevel, tint: tint)] = UInt8(index)
                for level in stride(from: maxLevel - 1, through: 0, by: -1) {
                    var j = snap(target(Apollo.oklab[index], level: level, tint: tint))
                    if Apollo.oklab[j].L > Apollo.oklab[above].L { j = above }
                    table[offset(index: index, level: level, tint: tint)] = UInt8(j)
                    above = j
                }
            }
        }
        return table
    }
}
