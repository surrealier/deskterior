/// A revealed desk pile drawn into the desk-surface raster as an upright billboard with per-pixel depth.
public struct PileBillboard: Sendable {
    /// Pile id (≥ 0); its pixels own `DeskSurfaceRaster.pileOwner(id)`.
    public let id: Int
    public var sprite: PixelBuffer
    /// Desk point `(x, d, z)` under the sprite's bottom-centre.
    public var position: SIMD3<Float>

    /// Nil for a negative id, which `owner[]` cannot encode.
    public init?(id: Int, sprite: PixelBuffer, position: SIMD3<Float>) {
        guard id >= 0, id < Int(Int32.max) - 2 else { return nil }
        self.id = id
        self.sprite = sprite
        self.position = position
    }
}

/// G-buffer texel.
struct SurfaceTexel {
    /// z · 256 (+ bias for back faces); `Int32.min` when empty.
    var depth: Int32
    /// Material coordinates · 16.
    var u: Int32
    var v: Int32
    /// Shading level · 1024 (0…4, flat = 2).
    var light: Int32
    /// Height above the floor the cloth rests on · 16 (top faces; felt lying on a bump takes the bump's light).
    var lift: Int32 = 0
    /// `BumpShading` flags of felt resting on a bump (its outline, no mesh creases).
    var bump: UInt8 = 0
    var owner: Int32
    var kind: UInt8
    var color: RGBA8

    static let empty = SurfaceTexel(depth: .min, u: 0, v: 0, light: 0, owner: -1, kind: 0, color: .clear)
}

/// The desk-surface layer (DESIGN §2.2 E9, rendering): the mat cloth plus revealed pile billboards, z-buffered,
/// shaded and outlined into a fixed 496×104 buffer covering core x 8–504, y 144–248.
///
/// Pure and deterministic: vertices snap to 1/16-px fixed point; coverage uses integer edge functions with the
/// top-left fill rule and every attribute is interpolated in integers, so output is bit-exact in any build.
/// Alongside the image, `owner[]` names what each pixel shows: −1 empty, ≥ 0 a particle id, ≤ −2 a pile.
public struct DeskSurfaceRaster: Sendable {
    public static let width = 496
    public static let height = 104
    /// Core art position of buffer pixel (0, 0).
    public static let origin = ArtPoint(8, 144)

    static let kindEmpty: UInt8 = 0
    static let kindFront: UInt8 = 1
    static let kindBack: UInt8 = 2
    static let kindFrontThread: UInt8 = 3
    static let kindBackThread: UInt8 = 4
    static let kindPile: UInt8 = 5

    /// Depth units per px.
    static let depthScale: Float = 256
    /// A folded flap's underside wins ties against the layer under it by this much (½ px); a face-up slope seen
    /// from behind (steeper than the view) loses ties by as much, so it never leaks past the face hiding it.
    static let backBias: Int32 = 128
    /// Shading-level fractions (·1024) between which neighbouring levels are Bayer-dithered.
    static let ditherLow = 358
    static let ditherHigh = 666
    /// Neighbour depth jump (1.5 px) that draws a crease or a contour where the cloth passes behind itself.
    static let creaseJump: Int32 = 384
    /// Neighbouring pixels whose owning particles are this many grid steps apart or fewer lie on one continuous
    /// stretch of cloth; farther apart, the nearer pixel is the edge of a layer lying over another.
    static let layerSteps = 2
    /// Below this shading change per pixel (levels · 1024) a face counts as flat and takes the nearest level instead
    /// of a dither, so planar faces stay one solid colour.
    static let ditherGradient = 12
    /// A triangle casts a shadow only when all of it is off the floor (min lift, px · 16) and part of it is clearly
    /// lifted (max lift), so creases and contact lines never shadow the layer they rest on.
    static let shadowMinLift: Int32 = 24
    static let shadowLift: Int32 = 48
    /// Light from the upper left (−x, a little from the front, mostly above), normalized: bumps keep felt-coloured
    /// fronts and lit left flanks, and only their right flanks shade.
    static let light = SIMD3<Float>(-0.6, -0.2, 0.8) / (1.04 as Float).squareRoot()
    /// Levels per unit of `n·L` change: slopes toward the light brighten faster than slopes away darken, so the
    /// viewer-facing slopes that fill most of this oblique view stay felt-coloured and only turned-away faces darken.
    static let shadeGainLit: Float = 4.5
    static let shadeGainDark: Float = 1.5
    /// Felt less than this far off its floor (px · 16) rests on it: on a bump it is drawn as the bump (`BumpShading`).
    static let bumpLiftBlend: Int32 = 12
    /// The ramp step of a bump's back-rim outline (flat felt is 3).
    static let rimShade = 1

    /// The shading level (· 1024, 0…4.999, flat = 2048) of a unit normal `(nx, ny, nz)` in desk space.
    @inline(__always)
    static func shadeLevel(_ nx: Float, _ ny: Float, _ nz: Float) -> Int32 {
        let L = light
        let diff = nx * L.x + ny * L.y + nz * L.z - L.z
        let s = 2 + diff * (diff > 0 ? shadeGainLit : shadeGainDark)
        return Int32((min(max(s, 0), 4.999) * 1024).rounded(.down))
    }

    public private(set) var image: PixelBuffer
    /// `width × height`, row-major: −1 empty, ≥ 0 particle id, ≤ −2 pile (`pileID(owner:)`).
    public private(set) var owner: [Int32]
    public var pattern: MatPattern {
        didSet { inks = RasterInks(pattern) }
    }

    var texels: [SurfaceTexel]
    /// The bump field's light for felt resting on bumps (M9).
    var bumpShading = BumpShading()
    /// Receiver depth of a cast shadow per pixel (`Int32.min` = none).
    var shadow: [Int32]
    /// Region written by the last render (buffer px).
    var dirty = ArtRect.zero
    /// Per-render scratch kept between renders.
    var verts = VertexSet()
    var inks: RasterInks

    public init(pattern: MatPattern = .felt) {
        self.pattern = pattern
        inks = RasterInks(pattern)
        image = PixelBuffer(width: Self.width, height: Self.height)
        owner = Array(repeating: -1, count: Self.width * Self.height)
        texels = Array(repeating: .empty, count: Self.width * Self.height)
        shadow = Array(repeating: .min, count: Self.width * Self.height)
    }

    public static func pileOwner(_ id: Int) -> Int32 { Int32(-2 - id) }

    public static func pileID(owner: Int32) -> Int? { owner <= -2 ? Int(-2 - owner) : nil }

    /// Owner at a core art point (−1 outside the buffer).
    public func owner(atCore p: ArtPoint) -> Int32 {
        let x = p.x - Self.origin.x, y = p.y - Self.origin.y
        guard x >= 0, y >= 0, x < Self.width, y < Self.height else { return -1 }
        return owner[y * Self.width + x]
    }

    /// Renders the cloth and pile billboards (drawn in order; ties keep the earlier one). With `bumps` (the field the
    /// cloth drapes over), felt resting on a bump is lit by the bump's own slope, so even a lone token's small mound
    /// reads under the coarse cloth mesh.
    public mutating func render(cloth: ClothSim, piles: [PileBillboard] = [], bumps: BumpField? = nil) {
        let previous = dirty
        clear(previous)
        bumpShading.update(bumps, projection: cloth.params.projection)
        var bounds = Bounds()
        verts.update(cloth: cloth)
        let verts = verts
        let matW = Int(cloth.restSize.x.rounded()), matD = Int(cloth.restSize.y.rounded())
        let pattern = pattern
        texels.withUnsafeMutableBufferPointer { T in
            shadow.withUnsafeMutableBufferPointer { S in
                let cols = cloth.cols
                for r in 0..<(cloth.rows - 1) {
                    for c in 0..<(cols - 1) {
                        let i = r * cols + c
                        rasterizeCloth(verts, i, i + 1, i + cols + 1, T, &bounds, pattern, matW, matD)
                        rasterizeCloth(verts, i, i + cols + 1, i + cols, T, &bounds, pattern, matW, matD)
                    }
                }
                for pile in piles { drawPile(pile, cloth.params.projection, T, &bounds) }
                for r in 0..<(cloth.rows - 1) {
                    for c in 0..<(cols - 1) {
                        let i = r * cols + c
                        castShadow(verts, i, i + 1, i + cols + 1, S, &bounds)
                        castShadow(verts, i, i + cols + 1, i + cols, S, &bounds)
                    }
                }
            }
        }
        dirty = bounds.rect
        shadeBumps(dirty, cloth.params.projection)
        resolve(dirty, matW: matW, matD: matD, cols: cloth.cols)
    }

    // MARK: - Bump light

    /// Felt resting on a bump is drawn as the bump: its light, its rim and contact outlines, and no mesh creases.
    private mutating func shadeBumps(_ r: ArtRect, _ proj: DeskProjection) {
        let b = bumpShading.rect.intersection(r)
        guard !b.isEmpty else { return }
        let w = Self.width, shading = bumpShading, rest = Self.bumpLiftBlend
        texels.withUnsafeMutableBufferPointer { T in
            for y in b.minY..<b.maxY {
                for x in b.minX..<b.maxX {
                    let i = y * w + x
                    guard T[i].kind == Self.kindFront, T[i].lift < rest, let s = shading.at(x, y) else { continue }
                    T[i].light = s.level
                    T[i].bump = s.flags
                }
            }
        }
    }

    // MARK: - Clear

    private mutating func clear(_ r: ArtRect) {
        guard !r.isEmpty else { return }
        let w = Self.width
        texels.withUnsafeMutableBufferPointer { T in
            shadow.withUnsafeMutableBufferPointer { S in
                owner.withUnsafeMutableBufferPointer { O in
                    image.withUnsafeMutablePixels { I in
                        for y in r.minY..<r.maxY {
                            let row = y * w
                            for x in r.minX..<r.maxX {
                                T[row + x] = .empty
                                S[row + x] = .min
                                O[row + x] = -1
                                I[row + x] = .clear
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Resolve

    private mutating func resolve(_ r: ArtRect, matW: Int, matD: Int, cols: Int) {
        guard !r.isEmpty else { return }
        let w = Self.width, h = Self.height
        let pattern = pattern, inks = inks
        let outlineColor = inks.outline, deskShadow = inks.deskShadow
        texels.withUnsafeBufferPointer { T in
            shadow.withUnsafeBufferPointer { S in
                owner.withUnsafeMutableBufferPointer { O in
                    image.withUnsafeMutablePixels { I in
                        for y in r.minY..<r.maxY {
                            for x in r.minX..<r.maxX {
                                let i = y * w + x
                                let t = T[i]
                                switch t.kind {
                                case Self.kindEmpty:
                                    if S[i] != .min { I[i] = deskShadow }
                                    continue
                                case Self.kindPile:
                                    // A revealed pile under lifted cloth stands in its shadow.
                                    I[i] = S[i] != .min ? inks.shaded(t.color) : t.color
                                    O[i] = t.owner
                                    continue
                                default:
                                    break
                                }
                                let back = t.kind == Self.kindBack || t.kind == Self.kindBackThread
                                let thread = t.kind == Self.kindFrontThread || t.kind == Self.kindBackThread
                                let ramp = back ? inks.under : inks.top
                                O[i] = t.owner
                                // Edges from the 4 neighbours (this pixel must be the nearer one): an outline against
                                // the desk, piles and other layers; a contour one shade darker where one stretch of
                                // cloth passes in front of itself or creases.
                                var edge = 0  // 0 none, 1 contour, 2 outline
                                var gradient: Int32 = 0
                                let onBump = t.bump != 0
                                if !thread {
                                    for k in 0..<4 {
                                        let nx = x + (k == 0 ? -1 : k == 1 ? 1 : 0)
                                        let ny = y + (k == 2 ? -1 : k == 3 ? 1 : 0)
                                        guard nx >= 0, ny >= 0, nx < w, ny < h else {
                                            edge = 2
                                            break
                                        }
                                        let n = T[ny * w + nx]
                                        if n.kind == Self.kindEmpty {
                                            edge = 2
                                            break
                                        }
                                        let nBack = n.kind == Self.kindBack || n.kind == Self.kindBackThread
                                        if n.kind != Self.kindPile && nBack == back {
                                            gradient = max(gradient, abs(n.light - t.light))
                                        }
                                        guard n.depth < t.depth else { continue }
                                        if n.kind == Self.kindPile || nBack != back {
                                            edge = 2
                                            break
                                        }
                                        // A bump's own outlines replace the coarse mesh's creases over it.
                                        if onBump && n.bump != 0 { continue }
                                        let a = Int(t.owner), b = Int(n.owner)
                                        let steps = max(abs(a % cols - b % cols), abs(a / cols - b / cols))
                                        let jump = t.depth - n.depth > Self.creaseJump
                                        if steps > Self.layerSteps && !jump {
                                            edge = 2
                                            break
                                        }
                                        if jump { edge = 1 }
                                    }
                                    if edge == 2 {
                                        I[i] = outlineColor
                                        continue
                                    }
                                }
                                let uPx = Int(t.u >> 4), vPx = Int(t.v >> 4)
                                let texel = back
                                    ? pattern.underside(u: uPx, v: vPx, width: matW, depth: matD)
                                    : pattern.top(u: uPx, v: vPx, width: matW, depth: matD)
                                let tone: Int
                                switch texel {
                                case .body(let k), .thread(let k): tone = k
                                case .gap: tone = 0
                                }
                                var level = Int(t.light)
                                if S[i] != .min && S[i] >= t.depth - 320 { level -= 1280 }
                                level = max(level, 0)
                                // Crisp bands; a short 4×4 Bayer ramp blends neighbouring levels only around each
                                // half-way boundary of a shading gradient. Flat faces take the nearest level.
                                let whole = level >> 10, frac = level & 1023
                                let lv: Int
                                if gradient < Self.ditherGradient {
                                    lv = whole + (frac >= 512 ? 1 : 0)
                                } else {
                                    let span = Self.ditherHigh - Self.ditherLow
                                    let ramp16 = min(max((frac - Self.ditherLow) * 16 / span, 0), 16)
                                    let bayer = Dither.bayer4(x: x + Self.origin.x, y: y + Self.origin.y)
                                    lv = whole + (bayer < ramp16 ? 1 : 0)
                                }
                                var shade = min(max(lv + 1 + tone, 0), 6)
                                if t.bump & BumpShading.rim != 0 { shade = min(shade, Self.rimShade) }
                                I[i] = ramp[edge == 1 ? max(shade - 1, 0) : shade]
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Resolved colours of a pattern's inks.
struct RasterInks {
    var top: [RGBA8]
    var under: [RGBA8]
    var outline: RGBA8
    var deskShadow: RGBA8
    /// Each Apollo colour two ramp steps darker (indexed by palette index), for piles in a cast shadow.
    var shadedByIndex: [RGBA8]

    init(_ pattern: MatPattern) {
        top = pattern.topRamp.map(\.color)
        under = pattern.undersideRamp.map(\.color)
        outline = pattern.outline.color
        deskShadow = pattern.deskShadow.color
        shadedByIndex = (0..<Apollo.count).map { Ink(palette: $0).darker(2).color }
    }

    func shaded(_ c: RGBA8) -> RGBA8 {
        guard let i = Apollo.index(of: c) else { return c }
        return shadedByIndex[i]
    }
}

// MARK: - Vertex setup

/// Per-particle fixed-point screen positions and attributes.
struct VertexSet {
    var sx: [Int32]
    var sy: [Int32]
    var depth: [Int32]
    var u: [Int32]
    var v: [Int32]
    var lightFront: [Int32]
    var lightBack: [Int32]
    var lift: [Int32]
    var valid: [Bool]
    /// Underside-up (part of a folded flap).
    var folded: [Bool]

    init() {
        (sx, sy, depth, u, v, lightFront, lightBack, lift) = ([], [], [], [], [], [], [], [])
        (valid, folded) = ([], [])
    }

    /// Recomputes every vertex for `cloth`, reusing the arrays.
    mutating func update(cloth: ClothSim) {
        let n = cloth.count, cols = cloth.cols, rows = cloth.rows
        let proj = cloth.params.projection
        let ox = Float(DeskSurfaceRaster.origin.x), oy = Float(DeskSurfaceRaster.origin.y)
        if sx.count != n {
            sx = Array(repeating: 0, count: n)
            (sy, depth, u, v, lightFront, lightBack, lift) = (sx, sx, sx, sx, sx, sx, sx)
            valid = Array(repeating: true, count: n)
            folded = valid
        }
        func fixed(_ f: Float, _ scale: Float) -> Int32? {
            let s = (f * scale).rounded(.toNearestOrAwayFromZero)
            guard s.isFinite, abs(s) < 1_000_000 else { return nil }
            return Int32(s)
        }
        let shade = DeskSurfaceRaster.shadeLevel
        cloth.parts.withUnsafeBufferPointer { P in
            cloth.uv.withUnsafeBufferPointer { UV in
                for r in 0..<rows {
                    let r0 = max(r - 1, 0) * cols, r1 = min(r + 1, rows - 1) * cols, row = r * cols
                    for c in 0..<cols {
                        let i = row + c
                        let p = SIMD3(P[i].x.x, P[i].x.y, P[i].x.z + P[i].ground)
                        guard let x = fixed(p.x - ox, 16), let y = fixed(proj.frontY - p.y * proj.k - p.z - oy, 16),
                              let z = fixed(p.z, DeskSurfaceRaster.depthScale),
                              let l = fixed(P[i].x.z - P[i].floorOffset, 16)
                        else {
                            valid[i] = false
                            continue
                        }
                        valid[i] = true
                        sx[i] = x
                        sy[i] = y
                        depth[i] = z
                        lift[i] = l
                        folded[i] = P[i].floorOffset != cloth.params.thickness
                        u[i] = Int32((UV[i].x * 16).rounded(.toNearestOrAwayFromZero))
                        v[i] = Int32((UV[i].y * 16).rounded(.toNearestOrAwayFromZero))
                        let a = abs3(P[row + min(c + 1, cols - 1)]) - abs3(P[row + max(c - 1, 0)])
                        let b = abs3(P[r1 + c]) - abs3(P[r0 + c])
                        let nx = a.y * b.z - a.z * b.y, ny = a.z * b.x - a.x * b.z, nz = a.x * b.y - a.y * b.x
                        let len = (nx * nx + ny * ny + nz * nz).squareRoot()
                        if len > 1e-6 && len.isFinite {
                            lightFront[i] = shade(nx / len, ny / len, nz / len)
                            lightBack[i] = shade(-nx / len, -ny / len, -nz / len)
                        } else {
                            lightFront[i] = 2048
                            lightBack[i] = 2048
                        }
                    }
                }
            }
        }
    }
}

@inline(__always)
private func abs3(_ p: ClothParticle) -> SIMD3<Float> { SIMD3(p.x.x, p.x.y, p.x.z + p.ground) }

/// Running bounding box of written pixels.
struct Bounds {
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min

    mutating func add(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        minX = min(minX, x0)
        minY = min(minY, y0)
        maxX = max(maxX, x1)
        maxY = max(maxY, y1)
    }

    var rect: ArtRect {
        guard minX <= maxX, minY <= maxY else { return .zero }
        return ArtRect(minX, minY, maxX - minX + 1, maxY - minY + 1)
    }
}

// MARK: - Triangle setup

/// Integer triangle setup: orientation, pixel bbox and top-left edge biases.
struct TriangleSetup {
    var ax, ay, bx, by, cx, cy: Int
    var area: Int
    /// Original winding was negative (y-down): the cloth's top face.
    var front: Bool
    /// Vertex slots after reordering to positive area: `order.1`/`order.2` may be swapped.
    var swapped: Bool
    var px0, px1, py0, py1: Int
    var biasA, biasB, biasC: Int

    init?(_ a: (Int, Int), _ b: (Int, Int), _ c: (Int, Int)) {
        var b = b, c = c
        var area = (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0)
        guard area != 0 else { return nil }
        front = area < 0
        swapped = front
        if front {
            swap(&b, &c)
            area = -area
        }
        self.area = area
        ax = a.0
        ay = a.1
        bx = b.0
        by = b.1
        cx = c.0
        cy = c.1
        let w = DeskSurfaceRaster.width, h = DeskSurfaceRaster.height
        px0 = max(0, ceilDiv(min(ax, bx, cx) - 8, 16))
        px1 = min(w - 1, floorDiv(max(ax, bx, cx) - 8, 16))
        py0 = max(0, ceilDiv(min(ay, by, cy) - 8, 16))
        py1 = min(h - 1, floorDiv(max(ay, by, cy) - 8, 16))
        // Weight of A comes from edge B→C, of B from C→A, of C from A→B.
        func bias(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            let dy = y1 - y0, dx = x1 - x0
            return dy < 0 || (dy == 0 && dx > 0) ? 0 : -1
        }
        biasA = bias(bx, by, cx, cy)
        biasB = bias(cx, cy, ax, ay)
        biasC = bias(ax, ay, bx, by)
    }

    var isEmpty: Bool { px0 > px1 || py0 > py1 }
}

@inline(__always)
func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

@inline(__always)
func ceilDiv(_ a: Int, _ b: Int) -> Int { -floorDiv(-a, b) }

// MARK: - Cloth triangles

@inline(__always)
private func rasterizeCloth(
    _ V: VertexSet, _ ia: Int, _ ib0: Int, _ ic0: Int, _ T: UnsafeMutableBufferPointer<SurfaceTexel>,
    _ bounds: inout Bounds, _ pattern: MatPattern, _ matW: Int, _ matD: Int
) {
    guard V.valid[ia], V.valid[ib0], V.valid[ic0] else { return }
    guard let s = TriangleSetup(
        (Int(V.sx[ia]), Int(V.sy[ia])), (Int(V.sx[ib0]), Int(V.sy[ib0])), (Int(V.sx[ic0]), Int(V.sy[ic0]))
    ), !s.isEmpty else { return }
    let ib = s.swapped ? ic0 : ib0, ic = s.swapped ? ib0 : ic0
    let front = s.front
    let w = DeskSurfaceRaster.width
    let za = Int(V.depth[ia]), zb = Int(V.depth[ib]), zc = Int(V.depth[ic])
    let ua = Int(V.u[ia]), ub = Int(V.u[ib]), uc = Int(V.u[ic])
    let va = Int(V.v[ia]), vb = Int(V.v[ib]), vc = Int(V.v[ic])
    let lights = front ? V.lightFront : V.lightBack
    let la = Int(lights[ia]), lb = Int(lights[ib]), lc = Int(lights[ic])
    let fa = Int(V.lift[ia]), fb = Int(V.lift[ib]), fc = Int(V.lift[ic])
    let bias = front ? 0
        : (V.folded[ia] || V.folded[ib] || V.folded[ic] ? 1 : -1) * Int(DeskSurfaceRaster.backBias)
    let area = s.area
    let fringe = pattern.fringe
    let onU = MatPattern.fringeOnU(width: matW, depth: matD)
    var wrote = false
    for py in s.py0...s.py1 {
        let y = py * 16 + 8
        var x = s.px0 * 16 + 8
        var wA = (s.cx - s.bx) * (y - s.by) - (s.cy - s.by) * (x - s.bx)
        var wB = (s.ax - s.cx) * (y - s.cy) - (s.ay - s.cy) * (x - s.cx)
        var wC = (s.bx - s.ax) * (y - s.ay) - (s.by - s.ay) * (x - s.ax)
        let dA = -(s.cy - s.by) * 16, dB = -(s.ay - s.cy) * 16, dC = -(s.by - s.ay) * 16
        for px in s.px0...s.px1 {
            defer {
                wA += dA
                wB += dB
                wC += dC
                x += 16
            }
            guard wA + s.biasA >= 0, wB + s.biasB >= 0, wC + s.biasC >= 0 else { continue }
            let depth = (wA * za + wB * zb + wC * zc) / area + bias
            let i = py * w + px
            guard depth > Int(T[i].depth) else { continue }
            let u = (wA * ua + wB * ub + wC * uc) / area, v = (wA * va + wB * vb + wC * vc) / area
            var kind = front ? DeskSurfaceRaster.kindFront : DeskSurfaceRaster.kindBack
            let uPx = u >> 4, vPx = v >> 4
            let across = onU ? min(uPx, matW - 1 - uPx) : min(vPx, matD - 1 - vPx)
            if across < fringe {
                let texel = front
                    ? pattern.top(u: uPx, v: vPx, width: matW, depth: matD)
                    : pattern.underside(u: uPx, v: vPx, width: matW, depth: matD)
                switch texel {
                case .gap: continue
                case .thread: kind = front ? DeskSurfaceRaster.kindFrontThread : DeskSurfaceRaster.kindBackThread
                case .body: break
                }
            }
            let nearest = wA >= wB && wA >= wC ? ia : (wB >= wC ? ib : ic)
            T[i] = SurfaceTexel(
                depth: Int32(clamping: depth), u: Int32(clamping: u), v: Int32(clamping: v),
                light: Int32(clamping: (wA * la + wB * lb + wC * lc) / area),
                lift: front ? Int32(clamping: (wA * fa + wB * fb + wC * fc) / area) : 0, owner: Int32(nearest),
                kind: kind, color: .clear
            )
            wrote = true
        }
    }
    if wrote { bounds.add(s.px0, s.py0, s.px1, s.py1) }
}

// MARK: - Shadows

/// Rasterizes the floor shadow of a lifted triangle: each vertex drops by its lift and shifts right by half of it
/// (light from the upper left). Stores the receiving floor depth.
@inline(__always)
private func castShadow(
    _ V: VertexSet, _ ia: Int, _ ib0: Int, _ ic0: Int, _ S: UnsafeMutableBufferPointer<Int32>, _ bounds: inout Bounds
) {
    guard V.valid[ia], V.valid[ib0], V.valid[ic0] else { return }
    guard max(V.lift[ia], V.lift[ib0], V.lift[ic0]) > DeskSurfaceRaster.shadowLift,
          min(V.lift[ia], V.lift[ib0], V.lift[ic0]) > DeskSurfaceRaster.shadowMinLift else { return }
    func pt(_ i: Int) -> (Int, Int) {
        let l = max(Int(V.lift[i]), 0)
        return (Int(V.sx[i]) + l / 2, Int(V.sy[i]) + l)
    }
    guard let s = TriangleSetup(pt(ia), pt(ib0), pt(ic0)), !s.isEmpty else { return }
    let ib = s.swapped ? ic0 : ib0, ic = s.swapped ? ib0 : ic0
    func recv(_ i: Int) -> Int { Int(V.depth[i]) - max(Int(V.lift[i]), 0) * 16 }
    let ra = recv(ia), rb = recv(ib), rc = recv(ic)
    let w = DeskSurfaceRaster.width
    var wrote = false
    for py in s.py0...s.py1 {
        let y = py * 16 + 8
        for px in s.px0...s.px1 {
            let x = px * 16 + 8
            let wA = (s.cx - s.bx) * (y - s.by) - (s.cy - s.by) * (x - s.bx)
            let wB = (s.ax - s.cx) * (y - s.cy) - (s.ay - s.cy) * (x - s.cx)
            let wC = (s.bx - s.ax) * (y - s.ay) - (s.by - s.ay) * (x - s.ax)
            guard wA + s.biasA >= 0, wB + s.biasB >= 0, wC + s.biasC >= 0 else { continue }
            let d = Int32(clamping: (wA * ra + wB * rb + wC * rc) / s.area)
            let i = py * w + px
            if d > S[i] { S[i] = d }
            wrote = true
        }
    }
    if wrote { bounds.add(s.px0, s.py0, s.px1, s.py1) }
}

// MARK: - Piles

/// Draws an upright billboard: sprite row `r` (from the top) stands `h − 1 − r` px above the pile's base.
@inline(__always)
private func drawPile(
    _ pile: PileBillboard, _ proj: DeskProjection, _ T: UnsafeMutableBufferPointer<SurfaceTexel>,
    _ bounds: inout Bounds
) {
    let sw = pile.sprite.width, sh = pile.sprite.height
    guard sw > 0, sh > 0, pile.position.x.isFinite, pile.position.y.isFinite, pile.position.z.isFinite else { return }
    let base = proj.project(pile.position)
    let left = DeskProjection.snap(base.x) - sw / 2 - DeskSurfaceRaster.origin.x
    let bottom = DeskProjection.snap(base.y) - DeskSurfaceRaster.origin.y  // first row below the sprite
    let w = DeskSurfaceRaster.width, h = DeskSurfaceRaster.height
    let owner = DeskSurfaceRaster.pileOwner(pile.id)
    var wrote = false
    pile.sprite.withUnsafePixels { src in
        for r in 0..<sh {
            let y = bottom - sh + r
            guard y >= 0 && y < h else { continue }
            let z = Int32(clamping: Int(((pile.position.z + Float(sh - 1 - r) + 0.5) * DeskSurfaceRaster.depthScale)
                .rounded(.down)))
            for c in 0..<sw {
                let x = left + c
                guard x >= 0 && x < w else { continue }
                let color = src[r * sw + c]
                guard color.a != 0 else { continue }
                let i = y * w + x
                guard z > T[i].depth else { continue }
                T[i] = SurfaceTexel(depth: z, u: 0, v: 0, light: 0, owner: owner, kind: DeskSurfaceRaster.kindPile,
                                    color: color)
                wrote = true
            }
        }
    }
    if wrote {
        bounds.add(max(left, 0), max(bottom - sh, 0), min(left + sw - 1, w - 1), min(bottom - 1, h - 1))
    }
}
