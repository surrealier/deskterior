/// A pile as coverage sees it: desk-plane centre, footprint half-size and the height of its top.
public struct CoveragePile: Hashable, Sendable {
    public var id: Int
    public var position: SIMD2<Float>
    public var radius: Float
    public var top: Float

    public init(id: Int, position: SIMD2<Float>, radius: Float = 6, top: Float = 3) {
        self.id = id
        self.position = position
        self.radius = radius
        self.top = top
    }

    /// The 5 footprint samples: centre and ±radius along x and d.
    public var samples: [SIMD2<Float>] {
        [position, position + SIMD2(-radius, 0), position + SIMD2(radius, 0),
         position + SIMD2(0, -radius), position + SIMD2(0, radius)]
    }
}

/// Covered/revealed state per pile with hysteresis (DESIGN §2.2 E9, hiding): ≥ 3/5 samples covered for
/// `coverFrames` consecutive updates → covered; ≤ 1/5 → revealed at once.
public struct CoverageTracker: Sendable {
    public static let coverFrames = 6
    public static let zMargin: Float = 6

    public private(set) var covered: [Int: Bool] = [:]
    private var streaks: [Int: Int] = [:]

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
        let index = ClothTriangleIndex(cloth)
        return update(samples: piles.map { (id: $0.id, covered: index.coveredSamples($0)) })
    }

    /// One frame of tracking from per-pile covered-sample counts (0…5).
    @discardableResult
    public mutating func update(samples: [(id: Int, covered: Int)]) -> [(id: Int, covered: Bool)] {
        var changes: [(id: Int, covered: Bool)] = []
        var seen = Set<Int>()
        for (id, k) in samples {
            seen.insert(id)
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
        covered = covered.filter { seen.contains($0.key) }
        streaks = streaks.filter { seen.contains($0.key) }
        return changes
    }
}

/// The cloth's triangles bucketed on an 8-px desk-plane grid, for point-under-cloth queries.
public struct ClothTriangleIndex: Sendable {
    static let cell: Float = 8
    static let origin = SIMD2<Float>(0, -8)
    static let gridW = 66
    static let gridH = 20

    private let xy: [SIMD2<Float>]
    private let z: [Float]
    /// Triangles as vertex index triples.
    private let tris: [SIMD3<Int32>]
    private let cellStart: [Int32]
    private let cellItems: [Int32]

    public init(_ cloth: ClothSim) {
        let pos = cloth.positions
        xy = pos.map { SIMD2($0.x, $0.y) }
        z = pos.map(\.z)
        var tris: [SIMD3<Int32>] = []
        tris.reserveCapacity((cloth.cols - 1) * (cloth.rows - 1) * 2)
        for r in 0..<(cloth.rows - 1) {
            for c in 0..<(cloth.cols - 1) {
                let i = Int32(r * cloth.cols + c), cols = Int32(cloth.cols)
                tris.append(SIMD3(i, i + 1, i + cols + 1))
                tris.append(SIMD3(i, i + cols + 1, i + cols))
            }
        }
        self.tris = tris
        let gw = Self.gridW, gh = Self.gridH
        var counts = [Int32](repeating: 0, count: gw * gh + 1)
        var ranges: [(Int, Int, Int, Int)] = []
        ranges.reserveCapacity(tris.count)
        for t in tris {
            let a = xy[Int(t.x)], b = xy[Int(t.y)], c = xy[Int(t.z)]
            let lo = pointwiseMin(a, pointwiseMin(b, c)), hi = pointwiseMax(a, pointwiseMax(b, c))
            let r = (Self.cellIndex(lo.x, Self.origin.x, gw), Self.cellIndex(lo.y, Self.origin.y, gh),
                     Self.cellIndex(hi.x, Self.origin.x, gw), Self.cellIndex(hi.y, Self.origin.y, gh))
            ranges.append(r)
            for cy in r.1...r.3 { for cx in r.0...r.2 { counts[cy * gw + cx + 1] += 1 } }
        }
        for k in 1..<counts.count { counts[k] += counts[k - 1] }
        var fill = counts
        var items = [Int32](repeating: 0, count: Int(counts[gw * gh]))
        for (ti, r) in ranges.enumerated() {
            for cy in r.1...r.3 {
                for cx in r.0...r.2 {
                    let k = cy * gw + cx
                    items[Int(fill[k])] = Int32(ti)
                    fill[k] += 1
                }
            }
        }
        cellStart = counts
        cellItems = items
    }

    private static func cellIndex(_ v: Float, _ o: Float, _ n: Int) -> Int {
        guard v.isFinite else { return 0 }
        return min(max(Int(((v - o) / cell).rounded(.down)), 0), n - 1)
    }

    /// Heights of every cloth layer above desk point `p`, lowest first.
    public func layers(at p: SIMD2<Float>) -> [Float] {
        let cx = Self.cellIndex(p.x, Self.origin.x, Self.gridW), cy = Self.cellIndex(p.y, Self.origin.y, Self.gridH)
        let k = cy * Self.gridW + cx
        var out: [Float] = []
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
            out.append(w0 * z[ia] + w1 * z[ib] + w2 * z[ic])
        }
        return out.sorted()
    }

    /// Whether some cloth layer lies over `p` lower than `maxZ`.
    public func isCovered(_ p: SIMD2<Float>, below maxZ: Float) -> Bool {
        guard let low = layers(at: p).first else { return false }
        return low < maxZ
    }

    /// How many of the pile's 5 footprint samples are covered (a layer with z < top + 6).
    public func coveredSamples(_ pile: CoveragePile) -> Int {
        pile.samples.reduce(0) { $0 + (isCovered($1, below: pile.top + CoverageTracker.zMargin) ? 1 : 0) }
    }
}
