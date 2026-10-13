/// A pile as coverage sees it: desk-plane centre and footprint half-size.
public struct CoveragePile: Hashable, Sendable {
    public var id: Int
    public var position: SIMD2<Float>
    public var radius: Float

    public init(id: Int, position: SIMD2<Float>, radius: Float = 6) {
        self.id = id
        self.position = position
        self.radius = radius
    }

    /// The 5 footprint samples: centre and ±radius along x and d.
    public var samples: [SIMD2<Float>] {
        [position, position + SIMD2(-radius, 0), position + SIMD2(radius, 0),
         position + SIMD2(0, -radius), position + SIMD2(0, radius)]
    }
}

/// Covered/revealed state per pile with hysteresis (DESIGN §2.2 E9, hiding): ≥ 3/5 samples covered for
/// `coverFrames` consecutive updates → covered; ≤ 1/5 → revealed at once.
///
/// A sample is covered when a cloth layer lies over it less than `zMargin` above the bump floor. Measuring from
/// the floor rather than from a pile's own top keeps the answer stable while the bump that covering raises grows
/// (a clustered group's bump is taller than any one member's).
public struct CoverageTracker: Sendable {
    public static let coverFrames = 6
    public static let zMargin: Float = 6

    public private(set) var covered: [Int: Bool] = [:]
    private var streaks: [Int: Int] = [:]
    private var index = ClothTriangleIndex()

    public init() {}

    public func isCovered(_ id: Int) -> Bool { covered[id] ?? false }

    /// Forces a state (restoring a saved layout).
    public mutating func setCovered(_ id: Int, _ value: Bool) {
        covered[id] = value
        streaks[id] = 0
    }

    /// One frame of tracking. Returns the piles whose state changed, in input order. Piles not passed are forgotten.
    @discardableResult
    public mutating func update(piles: [CoveragePile], cloth: ClothSim) -> [(id: Int, covered: Bool)] {
        index.update(cloth)
        var changes: [(id: Int, covered: Bool)] = []
        for pile in piles { track(pile.id, index.coveredSamples(pile), &changes) }
        forget(piles.count) { id in piles.contains { $0.id == id } }
        return changes
    }

    /// One frame of tracking from per-pile covered-sample counts (0…5).
    @discardableResult
    public mutating func update(samples: [(id: Int, covered: Int)]) -> [(id: Int, covered: Bool)] {
        var changes: [(id: Int, covered: Bool)] = []
        for (id, k) in samples { track(id, k, &changes) }
        forget(samples.count) { id in samples.contains { $0.id == id } }
        return changes
    }

    private mutating func track(_ id: Int, _ k: Int, _ changes: inout [(id: Int, covered: Bool)]) {
        if covered[id] ?? false {
            if k <= 1 {
                covered[id] = false
                streaks[id] = 0
                changes.append((id, false))
            }
        } else {
            covered[id] = false
            let streak = k >= 3 ? (streaks[id] ?? 0) + 1 : 0
            if streak >= Self.coverFrames {
                covered[id] = true
                streaks[id] = 0
                changes.append((id, true))
            } else {
                streaks[id] = streak
            }
        }
    }

    /// Drops piles that were not passed this frame (only when some were not: every passed id is in `covered`).
    private mutating func forget(_ passed: Int, _ contains: (Int) -> Bool) {
        guard covered.count != passed || streaks.count > covered.count else { return }
        covered = covered.filter { contains($0.key) }
        streaks = streaks.filter { contains($0.key) }
    }
}

/// The cloth's triangles bucketed on an 8-px desk-plane grid, for point-under-cloth queries. `update` reuses its
/// storage, so a tracker that keeps one does not allocate per frame.
public struct ClothTriangleIndex: Sendable {
    static let cell: Float = 8
    static let origin = SIMD2<Float>(0, -8)
    static let gridW = 66
    static let gridH = 20

    private var xy: [SIMD2<Float>] = []
    /// Absolute height and height above the bump floor per particle.
    private var z: [Float] = []
    private var clearance: [Float] = []
    /// Triangles as vertex index triples (fixed per grid size).
    private var tris: [SIMD3<Int32>] = []
    private var gridCols = 0
    private var cellStart: [Int32] = []
    private var cellFill: [Int32] = []
    private var cellItems: [Int32] = []
    private var ranges: [SIMD4<Int32>] = []

    public init() {}

    public init(_ cloth: ClothSim) {
        update(cloth)
    }

    /// Re-indexes the cloth's current pose.
    public mutating func update(_ cloth: ClothSim) {
        let n = cloth.count
        if xy.count != n {
            xy = Array(repeating: .zero, count: n)
            z = Array(repeating: 0, count: n)
            clearance = Array(repeating: 0, count: n)
        }
        if gridCols != cloth.cols || tris.count != (cloth.cols - 1) * (cloth.rows - 1) * 2 {
            gridCols = cloth.cols
            tris.removeAll(keepingCapacity: true)
            for r in 0..<(cloth.rows - 1) {
                for c in 0..<(cloth.cols - 1) {
                    let i = Int32(r * cloth.cols + c), cols = Int32(cloth.cols)
                    tris.append(SIMD3(i, i + 1, i + cols + 1))
                    tris.append(SIMD3(i, i + cols + 1, i + cols))
                }
            }
        }
        cloth.parts.withUnsafeBufferPointer { P in
            for i in 0..<n {
                xy[i] = SIMD2(P[i].x.x, P[i].x.y)
                z[i] = P[i].x.z + P[i].ground
                clearance[i] = P[i].x.z
            }
        }
        let gw = Self.gridW, gh = Self.gridH, cells = gw * gh
        if cellStart.count != cells + 1 {
            cellStart = Array(repeating: 0, count: cells + 1)
            cellFill = cellStart
        }
        for k in 0...cells { cellStart[k] = 0 }
        ranges.removeAll(keepingCapacity: true)
        for t in tris {
            let a = xy[Int(t.x)], b = xy[Int(t.y)], c = xy[Int(t.z)]
            let lo = pointwiseMin(a, pointwiseMin(b, c)), hi = pointwiseMax(a, pointwiseMax(b, c))
            let r = SIMD4(Int32(Self.cellIndex(lo.x, Self.origin.x, gw)), Int32(Self.cellIndex(lo.y, Self.origin.y, gh)),
                          Int32(Self.cellIndex(hi.x, Self.origin.x, gw)), Int32(Self.cellIndex(hi.y, Self.origin.y, gh)))
            ranges.append(r)
            for cy in Int(r.y)...Int(r.w) { for cx in Int(r.x)...Int(r.z) { cellStart[cy * gw + cx + 1] += 1 } }
        }
        for k in 1...cells { cellStart[k] += cellStart[k - 1] }
        for k in 0...cells { cellFill[k] = cellStart[k] }
        let total = Int(cellStart[cells])
        if cellItems.count < total { cellItems = Array(repeating: 0, count: total) }
        for (ti, r) in ranges.enumerated() {
            for cy in Int(r.y)...Int(r.w) {
                for cx in Int(r.x)...Int(r.z) {
                    let k = cy * gw + cx
                    cellItems[Int(cellFill[k])] = Int32(ti)
                    cellFill[k] += 1
                }
            }
        }
    }

    private static func cellIndex(_ v: Float, _ o: Float, _ n: Int) -> Int {
        guard v.isFinite else { return 0 }
        return min(max(Int(((v - o) / cell).rounded(.down)), 0), n - 1)
    }

    /// Calls `body` with the barycentric weights and vertex indices of every triangle over `p`.
    @inline(__always)
    private func forEachTriangle(at p: SIMD2<Float>, _ body: (Float, Float, Float, Int, Int, Int) -> Void) {
        guard !cellStart.isEmpty else { return }
        let cx = Self.cellIndex(p.x, Self.origin.x, Self.gridW), cy = Self.cellIndex(p.y, Self.origin.y, Self.gridH)
        let k = cy * Self.gridW + cx
        for s in Int(cellStart[k])..<Int(cellStart[k + 1]) {
            let t = tris[Int(cellItems[s])]
            let ia = Int(t.x), ib = Int(t.y), ic = Int(t.z)
            let a = xy[ia], b = xy[ib], c = xy[ic]
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            guard abs(area) > 1e-4 else { continue }
            let w0 = ((b.x - p.x) * (c.y - p.y) - (b.y - p.y) * (c.x - p.x)) / area
            let w1 = ((c.x - p.x) * (a.y - p.y) - (c.y - p.y) * (a.x - p.x)) / area
            let w2 = 1 - w0 - w1
            guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
            body(w0, w1, w2, ia, ib, ic)
        }
    }

    /// Absolute heights of every cloth layer above desk point `p`, lowest first.
    public func layers(at p: SIMD2<Float>) -> [Float] {
        var out: [Float] = []
        forEachTriangle(at: p) { w0, w1, w2, a, b, c in out.append(w0 * z[a] + w1 * z[b] + w2 * z[c]) }
        return out.sorted()
    }

    /// Height above the bump floor of the lowest cloth layer over `p`, or nil where no cloth lies.
    public func clearance(at p: SIMD2<Float>) -> Float? {
        var low = Float.infinity
        forEachTriangle(at: p) { w0, w1, w2, a, b, c in
            low = min(low, w0 * clearance[a] + w1 * clearance[b] + w2 * clearance[c])
        }
        return low < .infinity ? low : nil
    }

    /// Whether some cloth layer lies over `p` less than `CoverageTracker.zMargin` above the bump floor.
    public func isCovered(_ p: SIMD2<Float>) -> Bool {
        guard let c = clearance(at: p) else { return false }
        return c < CoverageTracker.zMargin
    }

    /// How many of the pile's 5 footprint samples are covered.
    public func coveredSamples(_ pile: CoveragePile) -> Int {
        let p = pile.position, r = pile.radius
        var k = 0
        for j in 0..<5 {
            let o: SIMD2<Float> = j == 0 ? .zero : j == 1 ? SIMD2(-r, 0) : j == 2 ? SIMD2(r, 0)
                : j == 3 ? SIMD2(0, -r) : SIMD2(0, r)
            if isCovered(p + o) { k += 1 }
        }
        return k
    }
}
