/// The desk knock (DESIGN §2.2 E11): a double-click on the apron (1 s cooldown) or a drawer slam.
///
/// A knock is an impulse that travels out from its origin: visible piles and floor tokens hop 2 px, the cup,
/// monitor, phone, lamp, plant and keyboard wobble, the cloth ripples, drawer contents and the basket heap
/// jiggle, and ajar non-jammed drawers within `knockReach` of their lower stop snap shut. It **never** changes
/// where a token lives: a `Plan` carries no locations, and the only model change it implies is those drawers'
/// openings. The scene runs them on its live sims (`DrawerSim.knock()`, which leaves a held or chomping drawer
/// alone) and commits each `settled` through the reducer (`.drawerSettled`); `actions` gives the same commits
/// without sims. Pure; the cooldown takes the time it is given.
public struct DeskKnock: Sendable, Equatable {
    public struct Params: Hashable, Sendable {
        public var cooldown: Double = 1
        /// Hop height (px) at full strength and its length in frames.
        public var hopHeight = 2
        public var hopFrames = 8
        public var wobbleFrames = 12
        /// How fast the knock spreads over the desk (plane px/s): farther things hop later.
        public var propagation: Float = 900
        /// Extra seeded delay (frames) so neighbours do not hop in lockstep.
        public var delayJitter = 2
        /// A slam this fast (px/s) knocks at full strength.
        public var fullSlamSpeed: Float = 300

        public init() {}

        public static let standard = Params()
    }

    /// One hop or wobble: starts after `delay` frames and lasts `frames`.
    public struct Hop: Hashable, Sendable {
        public var delay: Int
        public var height: Int
        public var frames: Int

        public init(delay: Int, height: Int, frames: Int) {
            self.delay = delay
            self.height = height
            self.frames = frames
        }

        /// Upward offset in px at frame `f` since the knock (a parabola: up, then back down).
        public func offset(atFrame f: Int) -> Int {
            let t = f - delay
            guard t >= 0, t < frames, frames > 1 else { return 0 }
            let u = Float(t) / Float(frames - 1)
            return Int((Float(height) * 4 * u * (1 - u)).rounded())
        }

        /// Wobble lean (−`height`…`height` px) at frame `f`: right, back, left, back, two frames each.
        public func lean(atFrame f: Int) -> Int {
            let t = f - delay
            guard t >= 0, t < frames else { return 0 }
            return [0, height, 0, -height][(t / 2) % 4]
        }

        public var endFrame: Int { delay + frames }
    }

    /// Props that wobble.
    public enum Wobbler: String, CaseIterable, Hashable, Sendable {
        case monitor, phone, penCup, lamp, plant, keyboard
    }

    public struct Plan: Hashable, Sendable {
        /// Desk-plane origin and strength (0…1).
        public var origin: SIMD2<Float>
        public var strength: Float
        public var pileHops: [PileID: Hop] = [:]
        public var floorHops: [TokenKey: Hop] = [:]
        public var wobbles: [Wobbler: Hop] = [:]
        /// Drawers that snap shut (each to its lower stop).
        public var drawerCloses: [ContainerID] = []
        /// Drawers whose contents jiggle (`ContentJostle.knock(strength:seed:)` with `seed`).
        public var drawerJostle: [ContainerID] = []
        /// The cloth ripples (`ClothSim.knock(from: origin, strength:)`).
        public var clothRipple = true
        public var basketJiggle = false
        public var seed: UInt64

        // MARK: harden
        /// The knock as Reduce Motion shows it (Errata 25): no hops, wobbles, jiggles or ripple; the drawers it snaps
        /// shut still shut, which is the only change a knock makes.
        public var stilled: Plan {
            var p = self
            p.pileHops = [:]
            p.floorHops = [:]
            p.wobbles = [:]
            p.drawerJostle = []
            p.clothRipple = false
            p.basketJiggle = false
            return p
        }

        /// Frames until every hop and wobble is over.
        public var frames: Int {
            max(pileHops.values.map(\.endFrame).max() ?? 0, floorHops.values.map(\.endFrame).max() ?? 0,
                wobbles.values.map(\.endFrame).max() ?? 0)
        }
    }

    public var params: Params
    public private(set) var lastKnock: Double?

    public init(params: Params = .standard) {
        self.params = params
    }

    /// Whether the cooldown has passed at time `now` (seconds).
    public func isReady(at now: Double) -> Bool {
        guard let last = lastKnock else { return true }
        return now - last >= params.cooldown
    }

    /// A knock at time `now`, or nil inside the cooldown. `drawers` are the live drawer sims (see `plan`).
    public mutating func knock(
        _ state: DeskState, drawers: [ContainerID: DrawerSim] = [:], at now: Double, origin: SIMD2<Float>,
        strength: Float = 1, seed: UInt64
    ) -> Plan? {
        guard isReady(at: now) else { return nil }
        lastKnock = now
        return Self.plan(for: state, drawers: drawers, origin: origin, strength: strength, seed: seed, params: params)
    }

    /// Strength of the knock a slam at `speed` px/s makes.
    public static func slamStrength(_ speed: Float, params: Params = .standard) -> Float {
        speed.isFinite ? min(max(speed / params.fullSlamSpeed, 0.25), 1) : 0
    }

    /// Desk-plane spots of the props that wobble.
    public static func wobblerPosition(_ w: Wobbler, state: DeskState) -> SIMD2<Float> {
        func back(_ r: ArtRect) -> SIMD2<Float> { SIMD2(Float(r.midX), 120) }
        switch w {
        case .monitor: return back(CoreLayout.monitorBody)
        case .phone: return back(CoreLayout.phone)
        case .penCup: return state.penCup.pos.isFinite ? state.penCup.pos : back(CoreLayout.penCup)
        case .lamp: return back(CoreLayout.lampBase)
        case .plant: return back(CoreLayout.plant)
        case .keyboard: return SIMD2(Float(CoreLayout.keyboard.midX), 52)
        }
    }

    /// The plan for a knock at desk-plane `origin` (pure). Drawers are judged by their live sims in `drawers`
    /// (where they are this frame, held or not), else by the saved openings. A put-away plant, phone stand or
    /// drawer is not in the room, so it neither wobbles nor shuts (Erratum 30).
    public static func plan(
        for state: DeskState, drawers: [ContainerID: DrawerSim] = [:], origin: SIMD2<Float>, strength: Float = 1,
        seed: UInt64, params: Params = .standard
    ) -> Plan {
        let o = origin.isFinite ? origin : SIMD2(Float(CoreLayout.apron.midX), 0)
        let s = strength.isFinite ? min(max(strength, 0), 1) : 0
        var rng = SplitMix64(seed: seed)
        var plan = Plan(origin: o, strength: s, seed: rng.next())
        let height = max(1, Int((Float(params.hopHeight) * s).rounded()))

        func hop(at p: SIMD2<Float>, frames: Int, height h: Int) -> Hop {
            let e = p - o
            let dist = (e * e).sum().squareRoot()
            let delay = Int((dist / params.propagation * 60).rounded()) + rng.nextInt(below: params.delayJitter + 1)
            return Hop(delay: delay, height: h, frames: frames)
        }

        for pile in state.piles.keys.sorted() {
            guard let p = state.piles[pile], p.isFinite else { continue }
            plan.pileHops[pile] = hop(at: p, frames: params.hopFrames, height: height)
        }
        for key in state.tokens.keys(where: { if case .floor = $0 { true } else { false } }) {
            guard case let .floor(x)? = state.tokens.location(of: key) else { continue }
            // Floor tokens are farther from the desk top: they hop half as high.
            plan.floorHops[key] = hop(at: SIMD2(Float(x), -40), frames: params.hopFrames, height: max(1, height / 2))
        }
        let away = Set(StowID.allCases.filter { !state.isOut($0) }.compactMap { StowCatalog.spec($0).wobbler })
        for w in Wobbler.allCases where !away.contains(w) {
            plan.wobbles[w] = hop(at: wobblerPosition(w, state: state), frames: params.wobbleFrames, height: 1)
        }
        for id in ContainerID.allCases where id.isDrawer && !state.isAway(id) {
            var sim = drawers[id] ?? DrawerSim(id, p: state.drawerOpening(id), count: state.tokens.count(in: id))
            if sim.knock() { plan.drawerCloses.append(id) }
            if state.tokens.count(in: id) > 0 { plan.drawerJostle.append(id) }
        }
        plan.basketJiggle = state.tokens.count(in: .wastebasket) > 0
        return plan
    }

    /// Where the drawers that snap shut come to rest (their lower stop).
    public static func drawerTargets(_ plan: Plan, state: DeskState) -> [ContainerID: Float] {
        var out: [ContainerID: Float] = [:]
        for id in plan.drawerCloses {
            out[id] = DrawerSim(id, p: state.drawerOpening(id), count: state.tokens.count(in: id)).closedLimit
        }
        return out
    }

    /// The commits the knock's motion ends in, for when no live sim runs it: each closing drawer settles at its
    /// lower stop. Nothing else.
    public static func actions(_ plan: Plan, state: DeskState) -> [DeskAction] {
        let targets = drawerTargets(plan, state: state)
        return plan.drawerCloses.compactMap { id in targets[id].map { .drawerSettled(id, $0) } }
    }
}
