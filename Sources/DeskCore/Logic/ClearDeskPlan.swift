import Foundation

/// Clear the Desk (DESIGN §2.2 E16, presentation mode): one layout change and one undo. The monitor goes off, the
/// phone face down and open drawers shut; a scripted brush pass sweeps every loose pile the mat does not cover yet
/// under the mat's nearest edge, and floor tokens arc onto the mat's edge and tuck under as new piles; then "TIDY!".
///
/// Pure and deterministic: the plan reads the model's mat (`MatState`, through `MatFootprint`), so every target lies
/// where the cloth covers a pile by the scene's own rule (all 5 footprint samples under it), clear of the keyboard. The
/// reducer applies the plan at once (`apply(to:grid:)`); the scene plays it (`AnimTarget.clearDesk`) with the times
/// here, so the model never waits for the animation. Layout only: no file changes.
public struct ClearDeskPlan: Sendable, Equatable {
    /// A loose pile the brush pushes under the mat.
    public struct Sweep: Sendable, Equatable {
        public var pile: PileID
        public var from: SIMD2<Float>
        /// Where it crosses the mat's edge, and where it comes to rest under the mat.
        public var edge: SIMD2<Float>
        public var to: SIMD2<Float>
        /// Seconds into the run when the brush reaches it, when it is at the mat's edge, and when it is under.
        public var contact: Float
        public var atEdge: Float
        public var under: Float
    }

    /// A floor stack thrown onto the mat's edge and tucked under it as a new pile.
    public struct Tuck: Sendable, Equatable {
        public var keys: [TokenKey]
        /// Core x of the stack's centre on the floor line.
        public var floorX: Int
        public var pile: PileID
        public var edge: SIMD2<Float>
        public var to: SIMD2<Float>
        /// Seconds into the run when it leaves the floor, lands on the mat's edge, and is under.
        public var start: Float
        public var land: Float
        public var under: Float
    }

    /// The brush at desk-plane point `at` at `t` seconds; it moves smoothly between keys.
    public struct BrushKey: Sendable, Equatable {
        public var t: Float
        public var at: SIMD2<Float>
    }

    public var powerOff = false
    public var phoneDown = false
    /// Drawers to shut, with the opening each rests at (its jam gap when overfull).
    public var shutDrawers: [ContainerID: Float] = [:]
    public var sweeps: [Sweep] = []
    public var tucks: [Tuck] = []
    /// Piles already under the mat that slide further in, because a pile sent under joins their bump.
    public var nudges: [PileID: SIMD2<Float>] = [:]
    /// The brush pass (empty when nothing is swept): from where it lies, pile by pile, and back.
    public var brush: [BrushKey] = []
    /// Seconds until "TIDY!".
    public var duration: Float = 0

    /// How far inside the mat's edges a tucked pile rests at least, so its bump does not hold the edge up off the desk.
    public static let tuckInset: Float = 16

    /// How far inside the mat's edges a stack of `n` tokens rests: `tuckInset`, or its bump's whole reach plus the
    /// hem (6 px), so a tall stack's slope never lifts the hem.
    public static func inset(count n: Int) -> Float {
        max(tuckInset, BumpField.extent(count: n) + 6)
    }
    /// Brush travel and push speeds (plane px/s), the slide under the edge and the brush's pause after each push (s).
    static let travelSpeed: Float = 520
    static let pushSpeed: Float = 260
    public static let slideTime: Float = 0.16
    static let pause: Float = 0.05
    /// A floor token's flight onto the mat's edge, and the gap between flights (s).
    public static let hopTime: Float = 0.42
    static let tuckStagger: Float = 0.11
    /// The brush pass is sped up to fit this many seconds; flights start within `maxTuckStart`.
    static let maxBrushTime: Float = 2.4
    static let maxTuckStart: Float = 1.4
    /// Seconds between the last pile going under and "TIDY!".
    public static let tidyDelay: Float = 0.2
    /// Half the brush's reach across a pile it pushes sideways and front-to-back (plane px): half a pile plus half
    /// the brush.
    static let reachX: Float = 7 + 12
    static let reachD: Float = 5 + 3

    public init() {}

    /// Whether applying the plan changes the layout.
    public var changesLayout: Bool {
        powerOff || phoneDown || !shutDrawers.isEmpty || !sweeps.isEmpty || !tucks.isEmpty || !nudges.isEmpty
    }

    // MARK: Planning

    /// The plan for desk `s`.
    public static func make(_ s: DeskState) -> ClearDeskPlan {
        var plan = ClearDeskPlan()
        plan.powerOff = s.monitor.power == .on
        plan.phoneDown = !s.phone.faceDown
        for id in ContainerID.allCases where id.isDrawer {
            let rest = Reducer.restingGap(id, s)
            if s.drawerOpening(id) > rest { plan.shutDrawers[id] = rest }
        }
        let mat = MatFootprint(s.mat)
        var targets = Targets(mat: mat, keyboard: s.mat.keyboardFootprint)

        // Loose piles: every pile holding tokens that the mat does not cover yet.
        var spots: [(at: SIMD2<Float>, count: Int)] = []
        var looseFrom: [(id: PileID, from: SIMD2<Float>)] = []
        var covered: [(id: PileID, at: SIMD2<Float>, count: Int)] = []
        for id in s.tokens.piles {
            guard let p = s.piles[id], p.isFinite else { continue }
            let n = s.tokens.members(of: id).count
            if mat.coveredSamples(at: p) >= 3 {
                covered.append((id, p, n))
            } else if let to = targets.take(near: p, count: n) {
                looseFrom.append((id, p))
                spots.append((to, n))
            }
        }

        // Floor stacks, left to right: each aims at the desk's front edge above it.
        var stacks: [Int: [TokenKey]] = [:]
        for k in s.tokens.sortedKeys {
            if case let .floor(x)? = s.tokens.location(of: k) { stacks[x, default: []].append(k) }
        }
        let xs = stacks.keys.sorted()
        let ids = s.makePileIDs(xs.count)
        var floorStacks: [(x: Int, pile: PileID)] = []
        for (i, x) in xs.enumerated() {
            guard let to = targets.take(near: SIMD2(Float(x), 0), count: stacks[x]!.count) else { continue }
            floorStacks.append((x, ids[i]))
            spots.append((to, stacks[x]!.count))
        }
        var under = covered.map { (at: $0.at, count: $0.count) }
        Self.spreadSharedBumps(&spots, covered: &under, targets: targets)
        for (pile, now) in zip(covered, under) where now.at != pile.at { plan.nudges[pile.id] = now.at }

        let loose = looseFrom.enumerated().map { i, pile in
            (id: pile.id, from: pile.from, edge: mat.edgeCrossing(from: pile.from, to: spots[i].at), to: spots[i].at)
        }
        let stagger = floorStacks.count > 1 ? min(tuckStagger, maxTuckStart / Float(floorStacks.count - 1)) : 0
        for (i, stack) in floorStacks.enumerated() {
            let aim = SIMD2(Float(stack.x), 0), to = spots[looseFrom.count + i].at
            let start = 0.1 + Float(i) * stagger
            plan.tucks.append(Tuck(keys: stacks[stack.x]!, floorX: stack.x, pile: stack.pile,
                                   edge: mat.edgeCrossing(from: aim, to: to), to: to, start: start,
                                   land: start + hopTime, under: start + hopTime + slideTime))
        }

        plan.planBrush(loose, from: s.brush.pos.isFinite ? s.brush.pos : BrushState().pos, around: mat)
        let ends = plan.sweeps.map(\.under) + plan.tucks.map(\.under) + [plan.brush.last?.t ?? 0]
        plan.duration = (ends.max() ?? 0) + tidyDelay
        return plan
    }

    /// Spots whose piles will share a bump (with each other, or with a pile already under the mat: `PileClusterer`'s
    /// 10 px) rest as far inside the edges as the shared, taller bump needs (`inset(count:)` of the group), so a group
    /// never holds the hem up where each pile alone would not. A pile already under the mat that joins such a group
    /// slides in with it (`covered`; only groups that gain a new pile move).
    static func spreadSharedBumps(_ spots: inout [(at: SIMD2<Float>, count: Int)],
                                  covered: inout [(at: SIMD2<Float>, count: Int)], targets: Targets) {
        let n = spots.count
        for _ in 0..<3 {
            let all = spots + covered
            let inputs = all.enumerated().map { PileInput(id: $0.offset, position: $0.element.at,
                                                          count: $0.element.count) }
            var moved = false
            for g in PileClusterer.groups(inputs) where g.ids.count > 1 && g.ids.contains(where: { $0 < n }) {
                let inset = Self.inset(count: g.count)
                for id in g.ids {
                    let q = targets.mat.clampedInside(all[id].at, inset: inset)
                    guard length2(q - all[id].at) > 1e-3, targets.fits(q) else { continue }
                    if id < n { spots[id].at = q } else { covered[id - n].at = q }
                    moved = true
                }
            }
            if !moved { return }
        }
    }

    /// The brush visits the loose piles nearest first, pushes each to the mat's edge, then goes back where it lay.
    /// Between pushes it goes round the mat (in front of it, or behind it when the mat lies at the desk's front), never
    /// across it and the keyboard.
    private mutating func planBrush(_ loose: [(id: PileID, from: SIMD2<Float>, edge: SIMD2<Float>, to: SIMD2<Float>)],
                                    from start: SIMD2<Float>, around mat: MatFootprint) {
        guard !loose.isEmpty else { return }
        var keys = [BrushKey(t: 0, at: start)]
        var at = start, t: Float = 0
        func travel(to b: SIMD2<Float>) {
            for p in Self.route(from: at, to: b, around: mat) {
                t += max(0.06, length2(p - at) / Self.travelSpeed)
                keys.append(BrushKey(t: t, at: p))
                at = p
            }
        }
        var left = loose
        while !left.isEmpty {
            let approaches = left.map { approach(for: $0.from, $0.edge, $0.to) }
            let i = left.indices.min { a, b in
                let da = length2(approaches[a].start - at), db = length2(approaches[b].start - at)
                return da != db ? da < db : left[a].id < left[b].id
            }!
            let pile = left.remove(at: i)
            let (a, b) = approaches[i]
            travel(to: a)
            let contact = t
            t += max(0.08, length2(b - a) / Self.pushSpeed)
            keys.append(BrushKey(t: t, at: b))
            sweeps.append(Sweep(pile: pile.id, from: pile.from, edge: pile.edge, to: pile.to, contact: contact,
                                atEdge: t, under: t + Self.slideTime))
            t += Self.pause
            keys.append(BrushKey(t: t, at: b))
            at = b
        }
        travel(to: start)
        // A long pass is sped up to fit.
        if t > Self.maxBrushTime {
            let k = Self.maxBrushTime / t
            for i in keys.indices { keys[i].t *= k }
            for i in sweeps.indices {
                sweeps[i].contact *= k
                sweeps[i].atEdge *= k
                sweeps[i].under = sweeps[i].atEdge + Self.slideTime
            }
        }
        brush = keys
    }

    /// The brush's way from `a` to `b`: straight, or, when that would cross the mat (and the brush's own half-length
    /// around it), along the desk's front (or back) past it.
    static func route(from a: SIMD2<Float>, to b: SIMD2<Float>, around mat: MatFootprint) -> [SIMD2<Float>] {
        let steps = max(2, Int(length2(b - a) / 4))
        let crosses = (1..<steps).contains { k in mat.isInside(a + (b - a) * (Float(k) / Float(steps)), inset: -12) }
        guard crosses else { return [b] }
        var lo: Float = .infinity, hi: Float = -.infinity
        for c in [SIMD2<Float>(0, 0), SIMD2(mat.size.x, 0), mat.size, SIMD2(0, mat.size.y)] {
            let p = mat.frame.point(c)
            lo = min(lo, p.y)
            hi = max(hi, p.y)
        }
        let desk = DeskPlanePhysics.desk
        let lane = lo - 9 >= desk.d + 3 ? lo - 9 : min(hi + 9, DeskPlanePhysics.backStripD - 4)
        return [SIMD2(a.x, lane), SIMD2(b.x, lane), b]
    }

    /// Where the brush starts pushing a pile and where it stops (the pile then at the mat's edge): behind it on the
    /// far side from the mat.
    private func approach(for from: SIMD2<Float>, _ edge: SIMD2<Float>, _ to: SIMD2<Float>)
        -> (start: SIMD2<Float>, stop: SIMD2<Float>)
    {
        var dir = edge - from
        if length2(dir) < 1e-3 { dir = to - from }
        let l = length2(dir)
        dir = l > 1e-3 ? dir / l : SIMD2(0, 1)
        let reach = abs(dir.x) * Self.reachX + abs(dir.y) * Self.reachD
        return (from - dir * reach, edge - dir * reach)
    }

    /// Resting spots under the mat, handed out nearest first: inside the mat's edges by `tuckInset`, where the cloth
    /// covers a whole pile footprint, clear of the keyboard. Spots already taken nudge later ones along the mat, so
    /// piles swept to one place stand close enough to share a bump (DESIGN O6) without overlapping exactly.
    struct Targets {
        let mat: MatFootprint
        let keyboard: DeskPlaneRect
        var taken: [SIMD2<Float>] = []
        /// The grid of candidate spots (plane px), computed once.
        private var grid: [SIMD2<Float>]?

        init(mat: MatFootprint, keyboard: DeskPlaneRect) {
            self.mat = mat
            // A pile keeps a footprint's radius plus a little from the keyboard.
            self.keyboard = DeskPlaneRect(x: keyboard.x - 10, d: keyboard.d - 8, width: keyboard.width + 20,
                                          depth: keyboard.depth + 16)
        }

        func fits(_ q: SIMD2<Float>) -> Bool {
            q.isFinite && !keyboard.contains(q) && mat.coveredSamples(at: q) == 5
        }

        mutating func take(near p: SIMD2<Float>, count: Int) -> SIMD2<Float>? {
            var spot = mat.clampedInside(p, inset: ClearDeskPlan.inset(count: count))
            if !fits(spot) {
                if grid == nil { grid = candidates() }
                guard let best = grid!.min(by: { length2($0 - p) < length2($1 - p) }) else { return nil }
                spot = best
            }
            // Spread spots that coincide along the mat's width, staying within one bump.
            let along = mat.frame.point(SIMD2(1, 0)) - mat.frame.point(.zero)
            var tries = 0
            while taken.contains(where: { length2($0 - spot) < 3 }), tries < 6 {
                let next = spot + along * (tries % 2 == 0 ? 4 : -4) * Float(tries / 2 + 1)
                if fits(next) { spot = next }
                tries += 1
            }
            taken.append(spot)
            return spot
        }

        private func candidates() -> [SIMD2<Float>] {
            var out: [SIMD2<Float>] = []
            let inset = ClearDeskPlan.tuckInset, size = mat.size
            for v in stride(from: inset, through: size.y - inset, by: 6) {
                for u in stride(from: inset, through: size.x - inset, by: 6) {
                    let q = mat.frame.point(SIMD2(u, v))
                    if fits(q) { out.append(q) }
                }
            }
            return out
        }
    }

    // MARK: Applying

    /// Writes the plan's layout into `s`: monitor off, phone face down, drawers shut, swept piles under the mat, the
    /// floor stacks there as new piles, and piles already under it nudged in where a new one joins their bump. Tokens
    /// that moved since the plan was made are left where they are.
    public func apply(to s: inout DeskState, grid: ScreenGrid = .standard) {
        if powerOff { s.monitor.power = .off }
        if phoneDown { s.phone.faceDown = true }
        for (id, p) in shutDrawers { s.drawers[id] = DrawerState(p: p) }
        for sweep in sweeps where !s.tokens.members(of: sweep.pile).isEmpty { s.piles[sweep.pile] = sweep.to }
        for (id, p) in nudges where s.piles[id] != nil && !s.tokens.members(of: id).isEmpty { s.piles[id] = p }
        for tuck in tucks {
            let live = tuck.keys.filter { s.tokens.location(of: $0) == .floor(x: tuck.floorX) }
            guard !live.isEmpty else { continue }
            s.piles[tuck.pile] = tuck.to
            for (i, k) in live.enumerated() { s.tokens.move(k, to: .desk(pile: tuck.pile, order: i), grid: grid) }
        }
        Placement.pruneEmptyPiles(&s)
    }

    // MARK: Playing

    /// Where the brush is `t` seconds into the run (smoothstep between keys); nil when there is no brush pass.
    public func brushPosition(at t: Float) -> SIMD2<Float>? {
        guard let first = brush.first else { return nil }
        if t <= first.t { return first.at }
        for (a, b) in zip(brush, brush.dropFirst()) where t < b.t {
            let u = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1
            return a.at + (b.at - a.at) * (u * u * (3 - 2 * u))
        }
        return brush.last!.at
    }

    /// Where a swept pile is `t` seconds into the run: where it lay until the brush reaches it, then pushed with the
    /// brush to the mat's edge, then sliding under to its rest.
    public static func position(of sweep: Sweep, at t: Float) -> SIMD2<Float> {
        if t <= sweep.contact { return sweep.from }
        if t < sweep.atEdge {
            let u = (t - sweep.contact) / max(sweep.atEdge - sweep.contact, 1e-3)
            return sweep.from + (sweep.edge - sweep.from) * (u * u * (3 - 2 * u))
        }
        let u = min(1, (t - sweep.atEdge) / max(sweep.under - sweep.atEdge, 1e-3))
        return sweep.edge + (sweep.to - sweep.edge) * (1 - (1 - u) * (1 - u))
    }
}
