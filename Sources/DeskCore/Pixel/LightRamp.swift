import Foundation

/// The hue a dimmed pixel drifts toward: moonlight / outdoor light (`cool`, toward `253a5e`), lamplight
/// (`warm`, toward `de9e41`), or a screen's cold white light (`screen`: as `cool`, but wood turns grey-blue
/// instead of keeping its tan, so the monitor's and phone's glows never read as a warm lamp). Ambient light is only ever
/// `cool` or `warm`; `screen` is for light masks.
public enum Tint: Int, Sendable, CaseIterable {
    case cool, warm, screen
}

/// Precomputed relighting table (DESIGN §1.4): palette index × light level 0…7 × tint → palette index.
///
/// Level 7 is the identity. Lower levels compress OKLab lightness toward the palette's floor, fade
/// chroma, and blend a/b toward the tint's hue with a weight that grows as the level drops; lamplight
/// (`warm`) also lifts wood, walls, paper and felt along its hue at the bright levels 3–6, so a lamp-lit
/// desk reads warm, not merely dimmer. The target is snapped to Apollo (OKLab, chroma weighted ×2). To keep
/// hue families coherent, a colour may only
/// snap to its own ramp, the tint's ramps (blue and purple for `cool`, walnut and oak for `warm`) or the
/// four darkest neutrals; leaving the own ramp costs a bias that fades with the level, and a column moves
/// one way only (own ramp → tint ramps → dark neutrals). Each `(index, tint)` column is also monotonic: a
/// level is never lighter than the level above it. Screen light (`screen`) follows `cool`, except that oak and
/// walnut lose their hue to the cool greys and blues, never the felt mat's greys (M10 review: a monitor's glow on
/// the oak desk read as lamplight).
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
    /// Upload as a 2D `.r8Uint` texture of width 46 (index) × height 24 (row `tint * 8 + level`),
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
    /// colours instead of indices: a 46 × 24 `.rgba8Unorm` texture with `bytesPerRow` 184.
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

    private static func target(_ lab: OKLab, level: Int, tint: Tint, ownRamp: Apollo.Ramp) -> OKLab {
        let L = lab.L > lightnessFloor
            ? lightnessFloor + (lab.L - lightnessFloor) * lightnessScale(level: level)
            : lab.L
        let fade = lab.L > 0 ? pow(L / lab.L, chromaExponent) : 1
        let (hue, maxWeight) = tint == .warm ? (warmHue, 0.6) : (coolHue, 0.9)
        var w = maxWeight * pow(1 - Double(level) / Double(maxLevel), tintExponent)
        let glow = tint == .warm && warmFriendly(ownRamp) ? warmGlow[level] : 0
        if tint == .screen && screenGreys(ownRamp) {
            // Wood under a screen's light: its hue gives way to the cool grey's.
            w = max(w, screenWash)
            return OKLab(L: L, a: lab.a * fade * (1 - w) + screenGrey.a * w, b: lab.b * fade * (1 - w) + screenGrey.b * w)
        }
        return OKLab(
            L: L,
            a: lab.a * fade * (1 - w) + hue.a * w + glow * warmDirection.a,
            b: lab.b * fade * (1 - w) + hue.b * w + glow * warmDirection.b
        )
    }

    /// Lamplight's lift per level (OKLab chroma along the warm hue, levels 0…7): the tint blend alone fades out
    /// toward level 7, so without it a lamp-lit desk at 5–6 is only a darker desk.
    private static let warmGlow: [Double] = [0, 0, 0, 0.04, 0.06, 0.07, 0.06, 0]
    /// Under warm light, leaving the own ramp for walnut or oak costs only this share of `ownRampBias`.
    private static let warmBiasScale = 0.3
    /// The warm hue's a/b direction (unit length).
    private static let warmDirection: (a: Double, b: Double) = {
        let n = (warmHue.a * warmHue.a + warmHue.b * warmHue.b).squareRoot()
        return (warmHue.a / n, warmHue.b / n)
    }()

    /// Ramps lamplight visibly warms (wood, walnut, red, the greys of walls, paper, metal and felt; `biasScale`
    /// keeps metal grey at level 6); blue, green and purple only dim.
    private static func warmFriendly(_ ramp: Apollo.Ramp) -> Bool {
        ramp == .oak || ramp == .walnut || ramp == .red || ramp == .neutral
    }

    /// Screen light: the grey wood drifts toward (`819796`) and how much of its own hue it gives up.
    private static let screenGrey = OKLab(RGBA8(hex: 0x819796))
    private static let screenWash = 0.85
    /// Under screen light, leaving oak or walnut for a neutral grey costs only this share of `ownRampBias`.
    private static let screenBiasScale = 0.2

    /// Ramps a screen's light greys (the woods); everything else dims as under `cool`.
    private static func screenGreys(_ ramp: Apollo.Ramp) -> Bool {
        ramp == .oak || ramp == .walnut
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
    /// purple for `cool` and `screen`, walnut and oak for `warm`) and the four darkest neutrals; under `screen`,
    /// oak and walnut may also become the light neutrals, but never the felt mat's greys (`feltGreys`).
    static func candidates(for index: Int, tint: Tint) -> [Int] {
        let own = Apollo.ramp(of: index)
        var tintRamps: [Apollo.Ramp] = tint == .warm ? [.walnut, .oak] : [.blue, .purple]
        if tint == .screen && screenGreys(own) { tintRamps.append(.neutral) }
        var set = Set(own.indices).union(darkNeutrals)
        for ramp in tintRamps { set.formUnion(ramp.indices) }
        if tint == .screen && screenGreys(own) { set.subtract(feltGreys) }
        return set.sorted()
    }

    /// The felt mat's greys (`394a50`, `577277`): a glow on the desk must not turn it into felt.
    private static let feltGreys: Set<Int> = [Ink.neutral4.paletteIndex!, Ink.neutral5.paletteIndex!]

    /// The share of `ownRampBias` that leaving `index`'s ramp for one of the tint's costs at `level`: lamplight
    /// lets wood, red and the greys warm (but the room light's level 6 only the light greys of walls and paper, so
    /// metal stays grey), screen light lets wood grey; otherwise all of it.
    private static func biasScale(index: Int, level: Int, tint: Tint) -> Double {
        let own = Apollo.ramp(of: index)
        switch tint {
        case .warm where warmFriendly(own):
            return own == .neutral && level == 6 && index < Ink.neutral8.paletteIndex! ? 1 : warmBiasScale
        case .screen where screenGreys(own):
            return screenBiasScale
        default:
            return 1
        }
    }

    /// The candidate nearest `t` (L, plus a/b weighted by `chromaSnapWeight`) at or past `minStage`, with
    /// `ownRampBias` added outside the own ramp (`scale` of it toward the tint's ramps); ties go to the lowest
    /// index.
    private static func snap(
        _ t: OKLab, level: Int, scale tintScale: Double, among candidates: [Int], ownRamp: Apollo.Ramp, minStage: Int
    ) -> Int {
        var best = -1, bestD = Double.infinity
        for i in candidates where stage(of: i, ownRamp: ownRamp) >= minStage {
            let p = Apollo.oklab[i]
            let dL = t.L - p.L, da = t.a - p.a, db = t.b - p.b
            var d = dL * dL + chromaSnapWeight * (da * da + db * db)
            if Apollo.ramp(of: i) != ownRamp {
                let scale = darkNeutrals.contains(i) ? 1 : tintScale
                d += ownRampBias * Double(level) / Double(maxLevel) * scale
            }
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
                    let t = target(Apollo.oklab[index], level: level, tint: tint, ownRamp: ownRamp)
                    var j = snap(t, level: level, scale: biasScale(index: index, level: level, tint: tint),
                                 among: allowed, ownRamp: ownRamp, minStage: minStage)
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
