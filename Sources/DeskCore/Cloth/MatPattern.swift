/// The desk mat's surface design, sampled by material coordinates (art px) so it never stretches.
///
/// Both faces use a 7-step ramp: the rasterizer's shading level (0…4, flat = 2) plus the pattern's tone offset
/// picks `ramp[level + 1 + tone]`, so a flat, plain texel is `ramp[3]`.
public struct MatPattern: Hashable, Sendable {
    public var name: String
    /// Top face, dark → light; `topRamp[3]` is flat felt.
    public var topRamp: [Ink]
    /// Underside, dark → light; `undersideRamp[3]` is flat rubber.
    public var undersideRamp: [Ink]
    /// Silhouette and layer-edge outline.
    public var outline: Ink
    /// Opaque shadow cast on the bare desk under lifted cloth.
    public var deskShadow: Ink
    /// Felt speck spacing (art px): about two light specks and one dark one per `tile × tile` of material.
    public var tile: Int
    /// Border band width along u-edges and v-edges (v is halved on screen, so its band is wider in material px).
    public var bandU: Int
    public var bandV: Int
    /// Fringe length on the short edges (art px of material).
    public var fringe: Int

    public init(name: String, topRamp: [Ink], undersideRamp: [Ink], outline: Ink, deskShadow: Ink, tile: Int = 16,
                bandU: Int = 3, bandV: Int = 6, fringe: Int = 4) {
        precondition(topRamp.count == 7 && undersideRamp.count == 7, "mat ramps need 7 inks")
        self.name = name
        self.topRamp = topRamp
        self.undersideRamp = undersideRamp
        self.outline = outline
        self.deskShadow = deskShadow
        self.tile = tile
        self.bandU = bandU
        self.bandV = bandV
        self.fringe = fringe
    }

    /// Grey-blue felt (`Role.feltMat` flat, `Role.feltMatLight` lit) with a darker hem, light stitching and
    /// fringed short edges over a walnut rubber underside whose lit side stays a muted brown (the amber walnut
    /// steps are the lamp and LED glow colours).
    public static let felt = MatPattern(
        name: "felt",
        topRamp: [.neutral1, .neutral2, .neutral3, Role.feltMat, Role.feltMatLight, .neutral6, .neutral7],
        undersideRamp: [.red0, .walnut0, .walnut1, .walnut2, .oak2, .oak3, .oak3],
        outline: Role.outline,
        deskShadow: Role.deskShadow
    )

    /// What a texel is.
    public enum Texel: Hashable, Sendable {
        /// Mat body with a tone offset.
        case body(Int)
        /// A fringe thread with a tone offset (drawn without outline).
        case thread(Int)
        /// A gap between fringe threads (transparent).
        case gap
    }

    /// Whether the short edges are the u-edges (u = 0 and u = W), i.e. the mat is wider than deep.
    @inline(__always)
    static func fringeOnU(width: Int, depth: Int) -> Bool { width >= depth }

    /// Top-face texel at material px `(u, v)` on a `width × depth` mat.
    public func top(u: Int, v: Int, width: Int, depth: Int) -> Texel {
        if let t = fringeTexel(u: u, v: v, width: width, depth: depth, tone: 1) { return t }
        let onU = Self.fringeOnU(width: width, depth: depth)
        // Body coordinates: the fringe sits outside the hem.
        let u0 = onU ? u - fringe : u, w0 = onU ? width - 2 * fringe : width
        let v0 = onU ? v : v - fringe, d0 = onU ? depth : depth - 2 * fringe
        let eu = min(u0, w0 - 1 - u0), ev = min(v0, d0 - 1 - v0)
        let inBandU = eu < bandU, inBandV = ev < bandV
        if inBandU || inBandV {
            // Stitch dashes run along the middle of the hem.
            if inBandU && eu == bandU / 2 && ev >= bandV / 2 {
                return .body((v0 / 3) % 2 == 0 ? 2 : -1)
            }
            // Two material rows wide so the dashes survive the 2:1 depth squash at any phase.
            if inBandV && (ev == bandV / 2 || ev == bandV / 2 - 1) && eu >= bandU / 2 {
                return .body((u0 / 3) % 2 == 0 ? 2 : -1)
            }
            return .body(-1)
        }
        // Fibre specks scattered by a hash of the material cell, so no tile repeats; each spans two material rows
        // so the 2:1 depth squash never drops it.
        let cell = UInt64(UInt32(truncatingIfNeeded: u0)) << 32 | UInt64(UInt32(truncatingIfNeeded: v0 >> 1))
        let m = SplitMix64.mix(cell ^ 0x5EED_F17E) % UInt64(max(tile * tile, 8))
        return .body(m < 4 ? 1 : m < 6 ? -1 : 0)
    }

    /// Underside texel: rubber with a dot grid (dots two material rows tall, so the 2:1 squash keeps them), fringe
    /// threads darker.
    public func underside(u: Int, v: Int, width: Int, depth: Int) -> Texel {
        if let t = fringeTexel(u: u, v: v, width: width, depth: depth, tone: 0) { return t }
        let row = v / 8
        return .body((u + (row & 1) * 4) % 8 == 2 && (v % 8 == 4 || v % 8 == 5) ? -1 : 0)
    }

    private func fringeTexel(u: Int, v: Int, width: Int, depth: Int, tone: Int) -> Texel? {
        let onU = Self.fringeOnU(width: width, depth: depth)
        let along = onU ? v : u, across = onU ? min(u, width - 1 - u) : min(v, depth - 1 - v)
        guard across < fringe else { return nil }
        // Threads alternate with gaps along the edge (v is halved on screen, so its period doubles); a per-thread
        // hash makes the ends ragged.
        let period = onU ? 4 : 2
        guard along % period < period / 2 else { return .gap }
        let side: UInt64 = (onU ? u * 2 < width : v * 2 < depth) ? 0 : 0x9E37
        let shorten = Int(SplitMix64.mix(UInt64(along / period) &+ side) % 2)
        return across < shorten ? .gap : .thread(tone)
    }
}
