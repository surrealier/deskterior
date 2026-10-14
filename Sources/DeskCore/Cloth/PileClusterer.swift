/// A desk pile as the cloth sees it: an id, its desk-plane position `(x, d)` and how many tokens it holds.
public struct PileInput: Hashable, Sendable {
    public var id: Int
    public var position: SIMD2<Float>
    public var count: Int
    /// How much of its bump stands (0…1): a pile sliding in under the edge grows its bump as it goes (M9 review).
    public var scale: Float

    public init(id: Int, position: SIMD2<Float>, count: Int, scale: Float = 1) {
        self.id = id
        self.position = position
        self.count = count
        self.scale = scale
    }
}

/// Piles close enough to share one bump.
public struct PileGroup: Hashable, Sendable {
    /// Member pile ids, ascending.
    public var ids: [Int]
    /// Total tokens across the members.
    public var count: Int
    /// Bounding box of the member positions.
    public var minPosition: SIMD2<Float>
    public var maxPosition: SIMD2<Float>
    /// The largest member's `PileInput.scale`.
    public var scale: Float = 1
}

/// Groups covered piles by union-find: piles within `radius` px of each other (transitively) share a group.
public enum PileClusterer {
    public static func groups(_ piles: [PileInput], radius: Float = 10) -> [PileGroup] {
        let n = piles.count
        guard n > 0 else { return [] }
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var j = i
            while parent[j] != r {
                let next = parent[j]
                parent[j] = r
                j = next
            }
            return r
        }
        let r2 = radius * radius
        for a in 0..<n {
            for b in (a + 1)..<n {
                let d = piles[a].position - piles[b].position
                if d.x * d.x + d.y * d.y <= r2 {
                    let ra = find(a), rb = find(b)
                    if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
                }
            }
        }
        var byRoot: [Int: [Int]] = [:]
        var order: [Int] = []
        for i in 0..<n {
            let r = find(i)
            if byRoot[r] == nil { order.append(r) }
            byRoot[r, default: []].append(i)
        }
        return order.map { root in
            let members = byRoot[root] ?? []
            var lo = piles[members[0]].position, hi = lo
            var total = 0
            var scale: Float = 0
            for m in members {
                lo = pointwiseMin(lo, piles[m].position)
                hi = pointwiseMax(hi, piles[m].position)
                total += max(1, piles[m].count)
                scale = max(scale, min(max(piles[m].scale, 0), 1))
            }
            return PileGroup(ids: members.map { piles[$0].id }.sorted(), count: total, minPosition: lo, maxPosition: hi,
                             scale: scale)
        }
    }
}
