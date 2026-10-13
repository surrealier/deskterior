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
/// is snapped to Apollo (OKLab, chroma weighted ×2). To keep hue families coherent, a colour may only
/// snap to its own ramp, the tint's ramps (blue and purple for `cool`, walnut and oak for `warm`) or the
/// four darkest neutrals; leaving the own ramp costs a bias that fades with the level, and a column moves
/// one way only (own ramp → tint ramps → dark neutrals). Each `(index, tint)` column is also monotonic: a
/// level is never lighter than the level above it.
public struct LightRamp: Sendable {
    /// Number of light levels (0…7).
    public static let levelCount = 8
    /// The identity level.
    public static let maxLevel = 7

    /// The table, built on first use (cheap: 46 × 7 × 2 snaps). `prewarm()` builds it off the main thread.
    public static let shared = LightRamp()

    /// Builds `shared` on a background queue. Safe to call more than once.
    public static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async { _ = LightRamp.shared }
    }

    /// Flattened table, one palette index per byte at offset `((tint * 8) + level) * 46 + index`.
    /// Upload as a 2D `.r8Uint` texture of width 46 (index) × height 16 (row `tint * 8 + level`),
    /// `bytesPerRow` 46; the lit pass reads `ramp.read(uint2(index, tint * 8 + level))`.
    public let gpuBytes: [UInt8]

    /// Builds a fresh table; use `shared`.
    init() {
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

    /// Snap penalty (squared OKLab units) for leaving the source's own ramp, scaled by level / 7: hue
    /// families hold through the mid levels and the tint takes over only as the light fails.
    private static let ownRampBias = 0.02

    /// Where a candidate sits on a column's one-way path: the source's own ramp (0), then the tint's ramps (1),
    /// then the dark-neutral floor (2). A column never steps back, so its hue cannot flicker.
    private static func stage(of candidate: Int, ownRamp: Apollo.Ramp) -> Int {
        if darkNeutrals.contains(candidate) { return 2 }
        return Apollo.ramp(of: candidate) == ownRamp ? 0 : 1
    }

    /// The four darkest neutrals (`090a14` … `202e37`), allowed for every colour.
    private static let darkNeutrals = Apollo.Ramp.neutral.indices.prefix(4)

    /// Palette indices `index` may become under `tint`, ascending: its own ramp, the tint's ramps (blue and
    /// purple for `cool`, walnut and oak for `warm`) and the four darkest neutrals.
    static func candidates(for index: Int, tint: Tint) -> [Int] {
        let tintRamps: [Apollo.Ramp] = tint == .cool ? [.blue, .purple] : [.walnut, .oak]
        var set = Set(Apollo.ramp(of: index).indices).union(darkNeutrals)
        for ramp in tintRamps { set.formUnion(ramp.indices) }
        return set.sorted()
    }

    /// The candidate nearest `t` (L, plus a/b weighted by `chromaSnapWeight`) at or past `minStage`, with
    /// `ownRampBias` added outside the own ramp; ties go to the lowest index.
    private static func snap(
        _ t: OKLab, level: Int, among candidates: [Int], ownRamp: Apollo.Ramp, minStage: Int
    ) -> Int {
        var best = -1, bestD = Double.infinity
        for i in candidates where stage(of: i, ownRamp: ownRamp) >= minStage {
            let p = Apollo.oklab[i]
            let dL = t.L - p.L, da = t.a - p.a, db = t.b - p.b
            var d = dL * dL + chromaSnapWeight * (da * da + db * db)
            if Apollo.ramp(of: i) != ownRamp { d += ownRampBias * Double(level) / Double(maxLevel) }
            if d < bestD { (best, bestD) = (i, d) }
        }
        return best
    }

    static func build() -> [UInt8] {
        var table = [UInt8](repeating: 0, count: Tint.allCases.count * levelCount * Apollo.count)
        for tint in Tint.allCases {
            for index in 0..<Apollo.count {
                let ownRamp = Apollo.ramp(of: index)
                let allowed = candidates(for: index, tint: tint)
                var above = index, minStage = 0
                table[offset(index: index, level: maxLevel, tint: tint)] = UInt8(index)
                for level in stride(from: maxLevel - 1, through: 0, by: -1) {
                    let t = target(Apollo.oklab[index], level: level, tint: tint)
                    var j = snap(t, level: level, among: allowed, ownRamp: ownRamp, minStage: minStage)
                    if Apollo.oklab[j].L > Apollo.oklab[above].L { j = above }
                    table[offset(index: index, level: level, tint: tint)] = UInt8(j)
                    minStage = max(minStage, stage(of: j, ownRamp: ownRamp))
                    above = j
                }
            }
        }
        return table
    }
}
