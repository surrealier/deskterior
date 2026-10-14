/// The mat as the model holds it (`MatState`): its cloth, laid from the saved particles (or flat from its frame when
/// it has none yet), the triangle index coverage measures with, and the frame of its face-up layer. Clear the Desk
/// plans with it, so a pile it sends under the mat is covered by the same rule the scene's `CoverageTracker` applies
/// (DESIGN §2.2 E9 hiding: ≥ 3 of 5 footprint samples under the cloth).
public struct MatFootprint: Sendable {
    public let cloth: ClothSim
    public let index: ClothTriangleIndex
    /// Best-fit frame of the face-up layer (a folded flap does not skew it).
    public let frame: ClothFrame
    /// Rest width and depth.
    public let size: SIMD2<Float>

    public init(cloth: ClothSim) {
        self.cloth = cloth
        index = ClothTriangleIndex(cloth)
        frame = cloth.baseFrame()
        size = cloth.restSize
    }

    /// The saved mat (a flat one at its frame when it has no particles, or they do not decode).
    public init(_ mat: MatState, params: ClothParams = .standard) {
        self.init(cloth: ClothSim(state: mat, params: params) ?? ClothSim.flat(mat, params: params))
    }

    /// Footprint samples (of 5) of a pile at `p` with `radius` that the cloth covers.
    public func coveredSamples(at p: SIMD2<Float>, radius: Float = 6) -> Int {
        index.coveredSamples(CoveragePile(id: 0, position: p, radius: radius))
    }

    /// Whether desk point `p` lies on the mat's flat rectangle, at least `inset` px inside its edges.
    public func isInside(_ p: SIMD2<Float>, inset: Float = 0) -> Bool {
        let q = frame.material(p)
        return q.x >= inset && q.x <= size.x - inset && q.y >= inset && q.y <= size.y - inset
    }

    /// The point of the mat's rectangle inset by `inset` nearest to `p` (in the mat's own frame).
    public func clampedInside(_ p: SIMD2<Float>, inset: Float) -> SIMD2<Float> {
        let q = frame.material(p)
        let i = SIMD2(min(inset, size.x / 2), min(inset, size.y / 2))
        return frame.point(SIMD2(min(max(q.x, i.x), size.x - i.x), min(max(q.y, i.y), size.y - i.y)))
    }

    /// Where the segment `a → b` first enters the mat's rectangle (`b` when it never does, `a` when it starts inside).
    public func edgeCrossing(from a: SIMD2<Float>, to b: SIMD2<Float>) -> SIMD2<Float> {
        if isInside(a) { return a }
        let qa = frame.material(a), qb = frame.material(b), d = qb - qa
        var enter: Float = 0, leave: Float = 1
        for k in 0..<2 {
            let hi = k == 0 ? size.x : size.y
            if abs(d[k]) < 1e-6 {
                if qa[k] < 0 || qa[k] > hi { return b }
                continue
            }
            var t0 = (0 - qa[k]) / d[k], t1 = (hi - qa[k]) / d[k]
            if t0 > t1 { swap(&t0, &t1) }
            enter = max(enter, t0)
            leave = min(leave, t1)
        }
        guard enter <= leave else { return b }
        return a + (b - a) * enter
    }
}

extension MatState {
    /// The keyboard's size on the desk plane (`CoreLayout.keyboard`: 96 wide, plane d 40–64).
    public static let keyboardSize = SIMD2<Float>(Float(CoreLayout.keyboard.w), 24)
    /// Where the keyboard stands until the mat carries it elsewhere.
    public static let defaultKeyboard = SIMD2<Float>(Float(CoreLayout.keyboard.midX), 52)

    /// The keyboard's footprint on the plane: where it weighs the mat down (and piles keep clear of it).
    public var keyboardFootprint: DeskPlaneRect {
        let c = keyboard.flatMap { $0.isFinite ? $0 : nil } ?? Self.defaultKeyboard
        return DeskPlaneRect(x: c.x - Self.keyboardSize.x / 2, d: c.y - Self.keyboardSize.y / 2,
                             width: Self.keyboardSize.x, depth: Self.keyboardSize.y)
    }
}

extension ClothSim {
    /// A flat mat laid from a saved frame (origin, size, angle and grid), for a `MatState` without particles.
    public static func flat(_ mat: MatState, params: ClothParams = .standard) -> ClothSim {
        let ok = mat.grid.count == 2 && mat.grid.allSatisfy { (3...4096).contains($0) } && mat.grid[0] * mat.grid[1] <= 4096
        let size = mat.size.isFinite && mat.size.x > 0 && mat.size.y > 0 ? mat.size : MatState().size
        return ClothSim(origin: mat.origin.isFinite ? mat.origin : MatState().origin, size: size,
                        angle: mat.angle.isFinite ? mat.angle : 0, cols: ok ? mat.grid[0] : 35,
                        rows: ok ? mat.grid[1] : 15, params: params)
    }

    /// Best-fit rigid frame of the face-up particles (the layer a folded flap lies on), or of all of them when fewer
    /// than three face up.
    public func baseFrame() -> ClothFrame {
        let up = (0..<count).filter { !isFolded($0) }
        return up.count >= 3 ? fitFrame(up) : matFrame()
    }
}
