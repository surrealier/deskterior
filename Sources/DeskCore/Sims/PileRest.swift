/// Freezer policy (DESIGN §4.7): which desk-pile bodies are dynamic. A pile resting for `freezeAfter` seconds
/// becomes static; it thaws when a brush, cup or carried token comes near, on a knock, or when dragged. At most
/// `maxDynamic` bodies are dynamic: over budget, the longest-resting freeze first, and thaws beyond the budget go
/// nearest-first. Pure timers and thresholds; the scene applies the decisions to its bodies.
public struct PileFreezer: Sendable, Equatable {
    public struct Params: Hashable, Sendable {
        /// At rest below this speed (art px/s; 2 SpriteKit u/s).
        public var restSpeed: Float = 0.5
        public var freezeAfter: Float = 2
        public var maxDynamic = 120
        /// Nearby brush, cup or carried token thaws piles within this distance (plane px).
        public var thawRadius: Float = 28

        public init() {}

        public static let standard = Params()
    }

    /// What the scene must do to its bodies.
    public struct Changes: Equatable, Sendable {
        public var freeze: [PileID] = []
        public var thaw: [PileID] = []

        public init(freeze: [PileID] = [], thaw: [PileID] = []) {
            self.freeze = freeze
            self.thaw = thaw
        }

        public var isEmpty: Bool { freeze.isEmpty && thaw.isEmpty }
    }

    public var params: Params
    /// Seconds each dynamic pile has rested (absent = frozen).
    public private(set) var restTimes: [PileID: Float] = [:]
    public private(set) var frozen: Set<PileID> = []

    public init(params: Params = .standard) {
        self.params = params
    }

    public var dynamic: Set<PileID> { Set(restTimes.keys) }
    public var dynamicCount: Int { restTimes.count }
    public func isFrozen(_ pile: PileID) -> Bool { frozen.contains(pile) }

    /// Tracks exactly these piles. New piles start dynamic (they just arrived) unless `frozen` lists them (a
    /// relaunch restores piles frozen). Over budget, the excess freezes.
    public mutating func sync(_ piles: Set<PileID>, startFrozen: Set<PileID> = []) -> Changes {
        var changes = Changes()
        for p in restTimes.keys where !piles.contains(p) { restTimes[p] = nil }
        frozen.formIntersection(piles)
        for p in piles.sorted() where restTimes[p] == nil && !frozen.contains(p) {
            if startFrozen.contains(p) {
                frozen.insert(p)
            } else {
                restTimes[p] = 0
            }
        }
        changes.freeze = enforceBudget(keep: [])
        return changes
    }

    /// One frame: speeds of the dynamic piles. Piles resting `freezeAfter` seconds freeze.
    public mutating func update(speeds: [PileID: Float], dt: Float) -> Changes {
        var changes = Changes()
        for p in restTimes.keys.sorted() {
            let s = speeds[p] ?? 0
            if !s.isFinite || s >= params.restSpeed {
                restTimes[p] = 0
            } else {
                let t = restTimes[p]! + dt
                if t >= params.freezeAfter {
                    restTimes[p] = nil
                    frozen.insert(p)
                    changes.freeze.append(p)
                } else {
                    restTimes[p] = t
                }
            }
        }
        changes.freeze += enforceBudget(keep: [])
        return changes
    }

    /// A drag grabbed `pile`: it thaws whatever the budget (the longest-resting other pile freezes instead).
    public mutating func thaw(_ pile: PileID) -> Changes {
        var changes = Changes()
        if frozen.remove(pile) != nil { changes.thaw.append(pile) }
        restTimes[pile] = 0
        changes.freeze = enforceBudget(keep: [pile])
        return changes
    }

    /// A brush, cup or carried token at plane point `point`: frozen piles within `radius` (default `thawRadius`)
    /// thaw, nearest first, within the budget.
    public mutating func thaw(
        near point: SIMD2<Float>, radius: Float? = nil, positions: [PileID: SIMD2<Float>]
    ) -> Changes {
        let r = radius ?? params.thawRadius
        let near = frozen.compactMap { p -> (PileID, Float)? in
            guard let q = positions[p], q.isFinite else { return nil }
            let d = (q - point) * (q - point)
            let dist = (d.x + d.y).squareRoot()
            return dist <= r ? (p, dist) : nil
        }
        return thawNearestFirst(near)
    }

    /// A knock: every frozen pile thaws, nearest to `origin` first, within the budget.
    public mutating func thawAll(from origin: SIMD2<Float>, positions: [PileID: SIMD2<Float>]) -> Changes {
        let all = frozen.map { p -> (PileID, Float) in
            guard let q = positions[p], q.isFinite else { return (p, .infinity) }
            let d = (q - origin) * (q - origin)
            return (p, (d.x + d.y).squareRoot())
        }
        return thawNearestFirst(all)
    }

    /// Hard sleep: everything freezes.
    public mutating func freezeAll() -> Changes {
        let list = restTimes.keys.sorted()
        for p in list { frozen.insert(p) }
        restTimes = [:]
        return Changes(freeze: list)
    }

    mutating func thawNearestFirst(_ candidates: [(PileID, Float)]) -> Changes {
        var changes = Changes()
        let room = max(0, params.maxDynamic - restTimes.count)
        let ordered = candidates.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        for (p, _) in ordered.prefix(room) {
            frozen.remove(p)
            restTimes[p] = 0
            changes.thaw.append(p)
        }
        return changes
    }

    /// Freezes the longest-resting dynamic piles (not `keep`) until within budget.
    mutating func enforceBudget(keep: Set<PileID>) -> [PileID] {
        let excess = restTimes.count - params.maxDynamic
        guard excess > 0 else { return [] }
        let order = restTimes.filter { !keep.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var out: [PileID] = []
        for (p, _) in order.prefix(excess) {
            restTimes[p] = nil
            frozen.insert(p)
            out.append(p)
        }
        return out
    }
}

/// Watchdog policy (DESIGN §4.7): a pile whose position is not finite, whose centre left the desk (a pile may hang
/// over an edge; one whose centre goes over leaves on an arc before this sees it), or that stayed awake longer
/// than `awakeLimit` snaps to the nearest valid desk spot, or to the monitor when the desk has none.
public struct PileWatchdog: Sendable, Equatable {
    public struct Params: Hashable, Sendable {
        public var awakeLimit: Float = 10
        /// Bounds and spacing for valid spots (plane px).
        public var desk = DeskPlanePhysics.desk
        public var pileSize = DeskPlanePhysics.pileSize
        /// Search grid step.
        public var gridStep: Float = 2
        /// Where a pile with no finite history is searched from.
        public var fallback = SIMD2<Float>(256, 48)

        public init() {}

        public static let standard = Params()
    }

    public enum Reason: String, Hashable, Sendable {
        case notFinite, outOfBounds, awakeTooLong
    }

    public enum Verdict: Hashable, Sendable {
        case ok
        /// Snap the pile here (and log `reason`).
        case snap(to: SIMD2<Float>, reason: Reason)
        /// No valid desk spot: move the pile's tokens to the monitor.
        case toMonitor(reason: Reason)
    }

    public var params: Params
    /// Seconds each pile has been awake.
    public private(set) var awake: [PileID: Float] = [:]
    /// Last finite, in-bounds position per pile.
    public private(set) var lastGood: [PileID: SIMD2<Float>] = [:]

    public init(params: Params = .standard) {
        self.params = params
    }

    /// Checks one pile for this frame. `isAwake`: its body is dynamic and moving. `others` are the other piles'
    /// positions; `obstacles` extra footprints (the pen cup).
    public mutating func check(
        _ pile: PileID, position: SIMD2<Float>, isAwake: Bool, dt: Float,
        others: [SIMD2<Float>] = [], obstacles: [DeskPlaneRect] = []
    ) -> Verdict {
        guard let reason = problem(pile, position: position, isAwake: isAwake, dt: dt) else { return .ok }
        return resolve(pile, position: position, reason: reason, others: others, obstacles: obstacles)
    }

    /// The cheap half of `check`, run for every pile every step: advances the awake timer and says what is wrong
    /// (nil when nothing is), so the caller gathers the other piles only for a pile that must move.
    public mutating func problem(_ pile: PileID, position: SIMD2<Float>, isAwake: Bool, dt: Float) -> Reason? {
        if !position.isFinite { return .notFinite }
        if !isOnDesk(position) { return .outOfBounds }
        lastGood[pile] = position
        let t = isAwake ? (awake[pile] ?? 0) + dt : 0
        awake[pile] = t
        return t > params.awakeLimit ? .awakeTooLong : nil
    }

    /// The other half of `check`: where a pile with `reason` goes.
    public mutating func resolve(
        _ pile: PileID, position: SIMD2<Float>, reason: Reason, others: [SIMD2<Float>], obstacles: [DeskPlaneRect] = []
    ) -> Verdict {
        awake[pile] = 0
        let from = position.isFinite ? position : (lastGood[pile] ?? params.fallback)
        guard let spot = nearestValidSpot(to: from, others: others, obstacles: obstacles) else {
            return .toMonitor(reason: reason)
        }
        lastGood[pile] = spot
        return .snap(to: spot, reason: reason)
    }

    /// Whether a pile centred at `p` would sit inside furniture, `obstacles` or another pile's body (bodies are
    /// `pileSize` less `inset` on each axis, so piles resting against each other do not count), or off the desk.
    public func isCrowded(_ p: SIMD2<Float>, others: [SIMD2<Float>], obstacles: [DeskPlaneRect] = [],
                          inset: Float = DeskPlanePhysics.pileInset) -> Bool {
        guard isOnDesk(p) else { return true }
        let size = params.pileSize - inset
        let body = DeskPlaneRect.centred(at: p, size: size)
        if DeskPlanePhysics.footprints.values.contains(where: { $0.intersects(body) }) { return true }
        if obstacles.contains(where: { $0.intersects(body) }) { return true }
        return others.contains { q in q.isFinite && abs(q.x - p.x) < size.x && abs(q.y - p.y) < size.y }
    }

    /// Forgets piles that are gone.
    public mutating func retain(_ piles: Set<PileID>) {
        awake = awake.filter { piles.contains($0.key) }
        lastGood = lastGood.filter { piles.contains($0.key) }
    }

    /// A pile centre over the desk top (its body may hang over an edge).
    public func isOnDesk(_ p: SIMD2<Float>) -> Bool {
        let b = params.desk
        return p.isFinite && p.x >= b.x && p.x <= b.x + b.width && p.y >= b.d && p.y <= b.d + b.depth
    }

    /// A pile centre that keeps its whole body on the desk.
    public func inBounds(_ p: SIMD2<Float>) -> Bool {
        let h = params.pileSize / 2, b = params.desk
        return p.x >= b.x + h.x && p.x <= b.x + b.width - h.x && p.y >= b.d + h.y && p.y <= b.d + b.depth - h.y
    }

    /// Whether a pile centred at `p` sits in bounds, clear of furniture, `obstacles` and the `others`' bodies.
    public func isValidSpot(_ p: SIMD2<Float>, others: [SIMD2<Float>], obstacles: [DeskPlaneRect] = []) -> Bool {
        guard p.isFinite, inBounds(p) else { return false }
        let body = DeskPlaneRect.centred(at: p, size: params.pileSize)
        for f in DeskPlanePhysics.footprints.values where f.intersects(body) { return false }
        for o in obstacles where o.intersects(body) { return false }
        for q in others where q.isFinite && DeskPlaneRect.centred(at: q, size: params.pileSize).intersects(body) {
            return false
        }
        return true
    }

    /// The valid spot nearest to `p` on the search grid (ties: smaller x, then smaller d), or nil when the desk is
    /// full.
    public func nearestValidSpot(
        to p: SIMD2<Float>, others: [SIMD2<Float>], obstacles: [DeskPlaneRect] = []
    ) -> SIMD2<Float>? {
        let target = p.isFinite ? p : params.fallback
        let h = params.pileSize / 2, b = params.desk, s = params.gridStep
        let x0 = b.x + h.x, x1 = b.x + b.width - h.x, d0 = b.d + h.y, d1 = b.d + b.depth - h.y
        let nx = Int(((x1 - x0) / s).rounded(.down)), nd = Int(((d1 - d0) / s).rounded(.down))
        guard nx >= 0, nd >= 0 else { return nil }
        // The clamped point itself first (it is usually valid), then the grid by distance.
        let clamped = SIMD2(min(max(target.x, x0), x1), min(max(target.y, d0), d1))
        if isValidSpot(clamped, others: others, obstacles: obstacles) { return clamped }
        var candidates: [(dist: Float, p: SIMD2<Float>)] = []
        candidates.reserveCapacity((nx + 1) * (nd + 1))
        for i in 0...nx {
            for j in 0...nd {
                let q = SIMD2(x0 + Float(i) * s, d0 + Float(j) * s)
                let e = q - target
                candidates.append(((e * e).sum(), q))
            }
        }
        candidates.sort { a, b in
            a.dist != b.dist ? a.dist < b.dist : (a.p.x != b.p.x ? a.p.x < b.p.x : a.p.y < b.p.y)
        }
        return candidates.first { isValidSpot($0.p, others: others, obstacles: obstacles) }?.p
    }
}
