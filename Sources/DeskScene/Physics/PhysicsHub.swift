import DeskCore
import os
import SpriteKit

/// The desk plane and everything that leaves the hand (M7; DESIGN §2.1 fling, §2.2 E7, E8, E11, §4.6–§4.7): the
/// `DeskPlaneWorld` and its `PileBodies`, the `TossAnimator`, and the elements that live on them (loose piles, floor
/// tokens, the pen cup, the wastebasket, the apron's knock). It owns the rules for where things land:
///
/// - **releases** (`release`, called by `CarrySession` before its own drop): a release over the bare desk, one faster
///   than 250 px/s (`Ballistics.Params.frontFlingSpeed`) over no affordance, or one below the desk's front edge
///   leaves the hand on a `Ballistics` arc from the stack's base: a slow one drops onto the desk and slides on with the
///   hand's speed (`vd = −2·vy`), a fast one flies in the plane just in front of the desk to the floor or the basket. A
///   gentle drop at the basket's mouth hops in. Affordances (screen, containers, bonks) keep the carry's own drop;
/// - **landings**: on the desk a pile (joining one within 10 px, else a new body at the nearest free spot, the hand's
///   velocity handed over), on the floor a token at `FloorLine` x, in the basket a ball (SWISH! for a clean pass; a
///   full basket bonks it out beside itself). Carries commit with journaled actions (`dropOnDesk`, `move`); motion
///   the scene started on its own (push-offs, spills) commits with `settle`;
/// - **after each physics step** (`didSimulate`): rest commits (`pilesSettled`), push-offs, watchdog snaps;
/// - the **knock** (`knock`), and **hard sleep** (`settle`): flights land, bodies freeze, positions commit.
final class PhysicsHub {
    unowned let context: SceneContext
    let world = DeskPlaneWorld()
    let bodies: PileBodies
    let tosses: TossAnimator
    private(set) var piles: DeskPilesElement!
    private(set) var floor: FloorElement!
    private(set) var cup: PenCupElement!
    private(set) var basket: WastebasketElement!
    private(set) var apron: ApronElement!
    /// The latest input event's time (rim-drag speeds, the knock's cooldown).
    var eventTime: () -> Double = { 0 }
    /// Installed elements that take knocks.
    var knockables: () -> [any Knockable] = { [] }
    /// Hides the room's static cup and basket sprites (after every rebuild of the room).
    var hidePlacements: () -> Void = {}
    private var knocker = DeskKnock()
    private var seedCounter: UInt64 = 0
    /// Carries in the air and their flights.
    private var carryFlights: [ObjectIdentifier: (carry: CarrySession, flight: TossAnimator.Flight)] = [:]
    /// Spilled pens still to leave the lying cup, and the seconds until the next one.
    private var pendingPens: (spills: [PenCupMachine.Spill], keys: [TokenKey], wait: Double)?

    /// Within this distance (plane px) a landing joins a pile instead of starting one.
    static let joinRadius: Float = 10
    /// Seconds between pens leaving the cup, and between balls leaving the basket.
    static let penInterval = 0.08
    static let ballInterval = 0.05
    static let log = Logger(subsystem: "io.github.deskterior", category: "physics")

    init(context: SceneContext) {
        self.context = context
        bodies = PileBodies(world: world)
        tosses = TossAnimator(context: context, z: CGFloat(RoomLayer.underDesk.rawValue * 1000 + 900))
        piles = DeskPilesElement(hub: self)
        floor = FloorElement(hub: self)
        cup = PenCupElement(hub: self)
        basket = WastebasketElement(hub: self)
        apron = ApronElement(hub: self)
    }

    var state: DeskState? { context.state }

    /// Every element the hub runs.
    var elements: [any DeskElement] { [piles, floor, cup, basket, apron] }

    func dispatch(_ a: DeskAction) { context.dispatch(a) }

    // MARK: Geometry

    static let projection = DeskProjection.standard

    /// Canvas point (continuous) → core point.
    func core(_ canvas: SIMD2<Float>) -> SIMD2<Float> {
        let o = context.layout.coreOrigin
        return canvas - SIMD2(Float(o.x), Float(o.y))
    }

    /// Core point → canvas point.
    func canvas(core p: SIMD2<Float>) -> SIMD2<Float> {
        let o = context.layout.coreOrigin
        return p + SIMD2(Float(o.x), Float(o.y))
    }

    /// The desk-plane point under canvas point `p` (on the plane at height `z`).
    func plane(_ p: SIMD2<Float>, z: Float = 0) -> SIMD2<Float> {
        let q = Self.projection.unproject(core(p), z: z)
        return SIMD2(q.x, q.y)
    }

    /// The canvas point of desk point `(x, d, z)`.
    func canvas(plane p: SIMD2<Float>, z: Float = 0) -> SIMD2<Float> {
        canvas(core: Self.projection.project(SIMD3(p.x, p.y, z)))
    }

    /// Ballistics for the room as it stands: a tipped basket frees its spot and blocks where it lies (and catches
    /// nothing).
    var ballistics: Ballistics.Params {
        var p = Ballistics.Params.standard
        guard let s = state else { return p }
        p.floorAvoid = FloorLine.furniture(basket: s.wastebasket) + FloorLine.spans(floorCentres(s))
        if !basket.isUpright { p.basketX = -1000 }
        return p
    }

    /// Centres of the floor tokens (landings stand beside them).
    func floorCentres(_ s: DeskState) -> [Int] {
        s.tokens.keys { if case .floor = $0 { true } else { false } }
            .compactMap { if case let .floor(x)? = s.tokens.location(of: $0) { x } else { nil } }
    }

    /// Footprints piles keep clear of: the keyboard and the pen cup (the back strip is built in).
    var obstacles: [DeskPlaneRect] { world.obstacles }

    func nextSeed() -> UInt64 {
        seedCounter &+= 1
        return SplitMix64.mix((state.map { UInt64($0.tokens.count) } ?? 0) &* 0x9E37_79B9 ^ seedCounter)
    }

    /// Tokens hidden from the desk, floor and containers: in hand or in the air.
    var hiddenKeys: Set<TokenKey> {
        (context.screen?.carried ?? []).union(tosses.flyingKeys)
    }

    // MARK: Model

    /// Follows the model (the piles element calls this first on every apply).
    func apply(_ s: DeskState) {
        world.attach(to: world.root.scene)
        var shown: [PileID: SIMD2<Float>] = [:]
        for (id, p) in s.piles where !s.tokens.members(of: id).isEmpty { shown[id] = p }
        bodies.sync(shown)
        world.setFurniture("keyboard", DeskPlaneWorld.keyboardFootprint(s.mat.keyboard))
    }

    // MARK: Releases

    /// A carry let go at canvas `p` with `velocity` (canvas px/s): true when the hub flies it (the carry then waits
    /// in `.flying` for `landed()`). Bonks on the cup or the basket make them wobble; the carry still bonks.
    func release(_ carry: CarrySession, at p: SIMD2<Float>, velocity: SIMD2<Float>) -> Bool {
        guard let s = state else { return false }
        let r = carry.verdict
        if case .bonk? = r?.verdict {
            if r?.element == cup.id { cup.bonked() }
            if r?.element == basket.id { basket.bonked() }
            return false
        }
        let keys = carry.keys.map(s.currentKey).filter(s.tokens.contains)
        guard !keys.isEmpty else { return false }
        let base = carry.basePoint(at: p)
        if let r, r.element == basket.id, case .accept = r.verdict {
            // A gentle drop at the mouth: it hops in.
            let to = SIMD2(TossAnimator.mouth.x, TossAnimator.mouth.y + 3)
            let from = core(base)
            let path = TossAnimator.Path.hop(from: from, to: to, height: 6, duration: 0.18)
            fly(carry, keys: keys, path: path, crumples: true) { [unowned self] _ in
                landInBasket(keys, toss: nil, from: to, journaled: true)
            }
            return true
        }
        if let r, r.element != piles.id { return false }
        let v = velocity.isFinite ? velocity : .zero
        let speed = (v * v).sum().squareRoot()
        let start = core(base)
        let params = ballistics
        let below = start.y > Float(CoreLayout.deskFrontY)
        guard r != nil || speed > params.frontFlingSpeed || below else { return false }
        var release = Ballistics.release(at: start, velocity: v, lift: 0, params: params)
        if release.position.z == 0, release.position.y >= 0 {
            // Set down on the desk: the stack was held `CarrySession.lift` px above the point under its base.
            release.position.z = Float(CarrySession.lift)
        }
        let toss = Ballistics.toss(from: release.position, velocity: release.velocity, seed: nextSeed(), params: params)
        fly(carry, keys: keys, path: .toss(toss), crumples: toss.isIn || toss.rimHits > 0) { [unowned self] _ in
            land(keys, toss: toss, journaled: true)
        }
        return true
    }

    private func fly(_ carry: CarrySession, keys: [TokenKey], path: TossAnimator.Path, crumples: Bool,
                     land: @escaping (TossAnimator.Flight) -> Void) {
        carry.handOff()
        let stack = flightImage(keys)
        let id = ObjectIdentifier(carry)
        let flight = tosses.launch(keys, path: path, image: stack.image, base: stack.base, crumples: crumples,
                                   squashes: true) { [unowned self] f in
            carryFlights[id] = nil
            land(f)
            carry.landed()
        }
        carryFlights[id] = (carry, flight)
    }

    /// A carry cut short in the air (hard sleep, teardown): it lands now.
    func landNow(_ carry: CarrySession) {
        guard let f = carryFlights[ObjectIdentifier(carry)]?.flight else { return }
        tosses.land(f)
    }

    /// The stack image a flight shows (no shadow while airborne).
    func flightImage(_ keys: [TokenKey]) -> PileArt.Stack {
        let icons = keys.reversed().prefix(PileArt.maxIcons).compactMap { k in
            state?.tokens.meta(of: k).map { TokenArt.icon(k, $0, context) }
        }
        return PileArt.stack(Array(icons), count: keys.count, shadow: nil)
    }

    // MARK: Landings

    /// Where a toss of `keys` ended: commit it (journaled for a carry, `settle` for motion the scene started).
    func land(_ keys: [TokenKey], toss: Ballistics.Toss, journaled: Bool) {
        switch toss.landing {
        case let .desk(point):
            let v = toss.landingVelocity
            landOnDesk(keys, at: point, velocity: SIMD2(v.x, v.y), journaled: journaled)
        case let .floor(x):
            let end = toss.projection.project(toss.end)
            if toss.end.y > 1 {
                // Down beside the desk, behind the front floor line: it hops forward onto the line.
                let to = SIMD2(x, Float(CoreLayout.floorY))
                let stack = flightImage(keys)
                tosses.launch(keys, path: .hop(from: end, to: to, height: 4, duration: 0.14), image: stack.image,
                              base: stack.base) { [unowned self] _ in
                    landOnFloor(keys, x: Int(x.rounded()), journaled: journaled)
                }
            } else {
                landOnFloor(keys, x: Int(x.rounded()), journaled: journaled)
            }
        case .basket:
            landInBasket(keys, toss: toss, from: toss.projection.project(toss.end), journaled: journaled)
        }
    }

    func landOnFloor(_ keys: [TokenKey], x: Int, journaled: Bool) {
        guard let s = state else { return }
        let live = keys.map(s.currentKey).filter(s.tokens.contains)
        guard !live.isEmpty else { return }
        context.fx.puff(at: context.layout.point(ArtPoint(x, CoreLayout.floorY)))
        if journaled {
            dispatch(.move(live, to: .floor(x: x)))
        } else {
            let others = floorCentres(s).filter { c in !live.contains { s.tokens.location(of: $0) == .floor(x: c) } }
            let spots = Reducer.floorSpots(near: x, count: live.count, basket: s.wastebasket, occupied: others)
            dispatch(.settle(SettleReport(moves: zip(live, spots).map { .init(key: $0, to: .floor(x: $1)) })))
        }
    }

    /// Into the basket: SWISH! for a clean toss; a basket that cannot take them all bonks them out onto the floor
    /// beside it.
    func landInBasket(_ keys: [TokenKey], toss: Ballistics.Toss?, from: SIMD2<Float>, journaled: Bool) {
        guard let s = state else { return }
        let live = keys.map(s.currentKey).filter(s.tokens.contains)
        guard !live.isEmpty else { return }
        let inside = s.tokens.members(of: .wastebasket).filter { !live.contains($0) }.count
        let mouth = context.layout.point(ArtPoint(Int(TossAnimator.mouth.x), Int(TossAnimator.mouth.y) - 4))
        guard basket.isUpright, inside + live.count <= ContainerSpec.wastebasket.hardCap else {
            context.fx.pop(.bonk, at: mouth)
            context.shake(frames: 2)
            context.bonks += 1
            basket.bonked()
            let spot = FloorLine.freeSpot(near: Float(CoreLayout.wastebasket.maxX + 14), avoiding: ballistics.floorAvoid)
            let stack = flightImage(live)
            tosses.launch(live, path: .hop(from: from, to: SIMD2(Float(spot), Float(CoreLayout.floorY)), height: 14,
                                          duration: 0.3),
                          image: stack.image, base: stack.base) { [unowned self] _ in
                landOnFloor(live, x: spot, journaled: journaled)
            }
            return
        }
        if let toss, basket.recordToss(toss, count: inside) {
            context.fx.pop(.swish, at: mouth)
            context.fx.sparkle(at: mouth + ArtPoint(10, 2))
        }
        if journaled {
            dispatch(.move(live, to: .container(.wastebasket, order: inside)))
        } else {
            dispatch(.settle(SettleReport(moves: live.enumerated().map {
                .init(key: $0.element, to: .container(.wastebasket, order: inside + $0.offset))
            })))
        }
    }

    /// On the desk: joins a pile within `joinRadius` (one the movers do not wholly make up), else starts a pile at
    /// the nearest free spot with `velocity` (plane px/s).
    func landOnDesk(_ keys: [TokenKey], at point: SIMD2<Float>, velocity: SIMD2<Float>, journaled: Bool) {
        guard let s = state else { return }
        let live = keys.map(s.currentKey).filter(s.tokens.contains)
        guard !live.isEmpty else { return }
        let movers = Set(live)
        var others: [PileID: SIMD2<Float>] = [:]
        for (id, p) in bodies.positions where p.isFinite && !s.tokens.members(of: id).allSatisfy(movers.contains) {
            others[id] = p
        }
        var near: (id: PileID, p: SIMD2<Float>, d: Float)?
        for id in others.keys.sorted() {
            let p = others[id]!
            let d = simd_length(p - point)
            if near == nil || d < near!.d { near = (id, p, d) }
        }
        if let near, near.d <= Self.joinRadius {
            commitDesk(live, pile: near.id, at: near.p, journaled: journaled)
            bodies.thaw(near: near.p)
            return
        }
        let spot = bodies.watchdog.nearestValidSpot(to: point, others: Array(others.values), obstacles: obstacles) ?? point
        let id = s.makePileID()
        bodies.add(id, at: spot, velocity: velocity)
        commitDesk(live, pile: id, at: spot, journaled: journaled)
        if state?.piles[id] == nil { apply(state ?? s) }
    }

    private func commitDesk(_ keys: [TokenKey], pile: PileID, at: SIMD2<Float>, journaled: Bool) {
        if journaled {
            dispatch(.dropOnDesk(keys, pile: pile, at: at))
        } else {
            let start = state?.tokens.members(of: pile).filter { !keys.contains($0) }.count ?? 0
            dispatch(.settle(SettleReport(
                moves: keys.enumerated().map { .init(key: $0.element, to: .desk(pile: pile, order: start + $0.offset)) },
                piles: [pile: at]
            )))
        }
    }

    // MARK: Frames

    var needsFrames: Bool {
        tosses.needsFrames || bodies.isMoving || pendingPens != nil
    }

    /// One fixed step before the physics (the piles element runs it): flights, spilling pens.
    func step(_ dt: Double) {
        world.attach(to: world.root.scene)
        tosses.step(dt)
        stepPens(dt)
    }

    /// After SpriteKit stepped the world (DESIGN §4.6 step 5): the cup's prop, rest commits, push-offs, the watchdog.
    func didSimulate() {
        cup.afterPhysics()
        guard !world.piles.isEmpty, let s = state else { return }
        let report = bodies.afterStep(Float(FrameClock.step), obstacles: obstacles)
        for snap in report.snapped {
            Self.log.notice("watchdog: pile \(snap.pile.raw, privacy: .public) \(snap.reason.rawValue, privacy: .public)")
        }
        if !report.settled.isEmpty {
            bodies.didCommit(report.settled)
            dispatch(.pilesSettled(report.settled))
        }
        for (id, at, v) in report.pushedOff {
            let keys = s.tokens.members(of: id).filter { !hiddenKeys.contains($0) }
            guard !keys.isEmpty else { continue }
            let toss = Ballistics.pushOff(at: at, velocity: v, params: ballistics)
            let stack = flightImage(keys)
            tosses.launch(keys, path: .toss(toss), image: stack.image, base: stack.base,
                          crumples: toss.isIn || toss.rimHits > 0) { [unowned self] _ in
                land(keys, toss: toss, journaled: false)
            }
        }
        if !report.toMonitor.isEmpty {
            var occupied = s.tokens.occupiedCells
            var moves: [SettleReport.Move] = []
            for id in report.toMonitor {
                for k in s.tokens.members(of: id) {
                    let c = ScreenGrid.standard.firstFree(occupied)
                    occupied.insert(c)
                    moves.append(.init(key: k, to: c.location))
                }
            }
            dispatch(.settle(SettleReport(moves: moves)))
        }
        piles.refresh()
    }

    // MARK: Spills

    /// The lying cup spills its pens: each leaves the mouth `penInterval` after the last with a seeded impulse
    /// (`PenCupMachine.spill`) and slides as a pile; past an edge it flies off.
    func spillPens(right: Bool, from position: SIMD2<Float>) {
        guard let s = state else { return }
        let keys = s.tokens.members(of: .penCup).filter { !hiddenKeys.contains($0) }
        guard !keys.isEmpty else { return }
        let spills = PenCupMachine.spill(count: keys.count, from: position, right: right, seed: nextSeed(),
                                         ballistics: ballistics)
        // The top pen (last in) leaves first.
        pendingPens = (Array(spills.reversed()), keys, 0)
        stepPens(0)
    }

    private func stepPens(_ dt: Double) {
        guard var pending = pendingPens else { return }
        pending.wait -= dt
        while pending.wait <= 0, let spill = pending.spills.first, let s = state {
            let key = s.currentKey(for: pending.keys[spill.index])
            pending.spills.removeFirst()
            pending.wait += Self.penInterval
            guard s.tokens.location(of: key)?.container == .penCup else { continue }
            let id = s.makePileID()
            bodies.add(id, at: spill.start, velocity: spill.velocity)
            dispatch(.settle(SettleReport(moves: [.init(key: key, to: .desk(pile: id, order: 0))], piles: [id: spill.start])))
        }
        pendingPens = pending.spills.isEmpty ? nil : pending
    }

    /// The tipped basket lets its balls roll out to `WastebasketMachine.spillSpots`, uncrumpling as they land.
    func spillBalls(right: Bool) {
        guard let s = state else { return }
        let keys = s.tokens.members(of: .wastebasket).filter { !hiddenKeys.contains($0) }
        guard !keys.isEmpty else { return }
        let spots = WastebasketMachine.spillSpots(count: keys.count, right: right)
        let lying = WastebasketMachine.tippedRect(right: right)
        let mouth = SIMD2(Float(right ? lying.maxX - 3 : lying.minX + 3), Float(lying.midY + 4))
        for (i, (key, spot)) in zip(keys, spots).enumerated().reversed() {
            let to = SIMD2(Float(spot), Float(CoreLayout.floorY))
            // The top ball first; each one after waits its turn in the mouth.
            let rank = keys.count - 1 - i
            let duration = 0.18 + abs(to.x - mouth.x) / 500
            let icon = flightImage([key])
            tosses.launch([key], path: .hop(from: mouth, to: to, height: 8 + Float(rank % 3) * 3, duration: duration),
                          image: icon.image, base: icon.base, crumples: false, delay: Float(rank) * Float(Self.ballInterval),
                          look: .ball) { [unowned self] _ in
                landOnFloor([key], x: spot, journaled: false)
            }
        }
    }

    // MARK: Knock

    /// A desk knock from the apron at core x `x` (1 s cooldown): piles and floor tokens hop, props wobble, ajar
    /// drawers snap shut. Membership never changes.
    func knock(atCoreX x: Float) {
        guard let s = state else { return }
        let origin = SIMD2(x, 0)
        guard let plan = knocker.knock(s, at: eventTime(), origin: origin, seed: nextSeed()) else { return }
        bodies.thawAll(from: origin)
        let all = knockables()
        let claimed = all.reduce(into: Set<ContainerID>()) { $0.formUnion($1.knockedDrawers) }
        for k in all { k.knock(plan) }
        apron.wobble(plan)
        for case let .drawerSettled(id, p) in DeskKnock.actions(plan, state: s) where !claimed.contains(id) {
            dispatch(.drawerSettled(id, p))
        }
    }

    // MARK: Hard sleep

    /// Everything lands and freezes; resting positions commit.
    func settle() {
        tosses.landAll()
        while pendingPens != nil { stepPens(Self.penInterval) }
        tosses.landAll()
        let positions = bodies.freezeAll()
        if !positions.isEmpty {
            bodies.didCommit(positions)
            dispatch(.pilesSettled(positions))
        }
    }

    /// The flight carrying `carry`, if it is in the air (tests).
    func flight(of carry: CarrySession) -> TossAnimator.Flight? { carryFlights[ObjectIdentifier(carry)]?.flight }
}
