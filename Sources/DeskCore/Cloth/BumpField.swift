/// The desk floor under the cloth: a 2-px heightfield over the desk plane (244×64 nodes from x 12, d 0) where
/// each group of covered piles stamps a rounded-box bump (DESIGN §2.2 E9, bumps). Changes ease in over
/// `easeFrames` frames; every change bumps `revision`, which wakes the cloth.
public struct BumpField: Sendable {
    public static let cols = 244
    public static let rows = 64
    public static let cell: Float = 2
    /// Desk-plane position of node (0, 0).
    public static let origin = SIMD2<Float>(12, 0)
    public static let easeFrames = 15

    /// Current (eased) heights, row-major `rows × cols`.
    public private(set) var heights: [Float]
    public private(set) var groups: [PileGroup] = []
    public private(set) var revision: UInt64 = 0
    private var from: [Float]
    private var target: [Float]
    private var easeFrame = BumpField.easeFrames

    public init() {
        heights = Array(repeating: 0, count: Self.cols * Self.rows)
        from = heights
        target = heights
    }

    /// Bump height for a group of `n` tokens: `3 + 2·min(n−1, 6)`.
    public static func bumpHeight(count n: Int) -> Float { 3 + 2 * Float(min(max(n, 1) - 1, 6)) }

    /// Bump radius for a group of `n` tokens: `7 + min(n, 8)`.
    public static func bumpRadius(count n: Int) -> Float { 7 + Float(min(max(n, 1), 8)) }

    public var isEasing: Bool { easeFrame < Self.easeFrames }

    public var maxHeight: Float { heights.max() ?? 0 }

    /// Rebuilds the target from the covered piles (clustered with radius 10). With `animated` the change eases in
    /// over `easeFrames` calls to `advance()`; otherwise it applies at once.
    public mutating func setCoveredPiles(_ piles: [PileInput], animated: Bool = true) {
        let newGroups = PileClusterer.groups(piles, radius: 10)
        let newTarget = Self.stamp(newGroups)
        groups = newGroups
        guard newTarget != target else { return }
        target = newTarget
        if animated {
            from = heights
            easeFrame = 0
        } else {
            heights = newTarget
            from = newTarget
            easeFrame = Self.easeFrames
            revision &+= 1
        }
    }

    /// One frame of easing (smoothstep over `easeFrames`).
    public mutating func advance() {
        guard easeFrame < Self.easeFrames else { return }
        easeFrame += 1
        let t = Float(easeFrame) / Float(Self.easeFrames)
        let e = t * t * (3 - 2 * t)
        let target = target, from = from
        heights.withUnsafeMutableBufferPointer { h in
            for i in 0..<h.count { h[i] = from[i] + (target[i] - from[i]) * e }
        }
        revision &+= 1
    }

    /// Bilinear height at desk `(x, d)` (clamped at the grid edge).
    public func height(x: Float, d: Float) -> Float {
        withSampler { $0.height(x, d) }
    }

    func withSampler<R>(_ body: (HeightSampler) -> R) -> R {
        heights.withUnsafeBufferPointer { b in
            body(HeightSampler(
                base: b.baseAddress, nx: Self.cols, ny: Self.rows, x0: Self.origin.x, d0: Self.origin.y,
                invCell: 1 / Self.cell
            ))
        }
    }

    /// Max over groups of a rounded box: full height within `r/2` of the members' bounding box, smoothstep to 0
    /// at `r`.
    static func stamp(_ groups: [PileGroup]) -> [Float] {
        var out = [Float](repeating: 0, count: cols * rows)
        for g in groups {
            let h = bumpHeight(count: g.count), r = bumpRadius(count: g.count), plateau = r / 2
            let lo = g.minPosition - SIMD2(repeating: r), hi = g.maxPosition + SIMD2(repeating: r)
            let i0 = max(0, Int(((lo.x - origin.x) / cell).rounded(.down)))
            let i1 = min(cols - 1, Int(((hi.x - origin.x) / cell).rounded(.up)))
            let j0 = max(0, Int(((lo.y - origin.y) / cell).rounded(.down)))
            let j1 = min(rows - 1, Int(((hi.y - origin.y) / cell).rounded(.up)))
            guard i0 <= i1, j0 <= j1 else { continue }
            for j in j0...j1 {
                let d = origin.y + Float(j) * cell
                let dy = max(g.minPosition.y - d, 0, d - g.maxPosition.y)
                for i in i0...i1 {
                    let x = origin.x + Float(i) * cell
                    let dx = max(g.minPosition.x - x, 0, x - g.maxPosition.x)
                    let dist = (dx * dx + dy * dy).squareRoot()
                    guard dist < r else { continue }
                    var t = (dist - plateau) / (r - plateau)
                    t = min(max(t, 0), 1)
                    let v = h * (1 - t * t * (3 - 2 * t))
                    let k = j * cols + i
                    if v > out[k] { out[k] = v }
                }
            }
        }
        return out
    }
}
