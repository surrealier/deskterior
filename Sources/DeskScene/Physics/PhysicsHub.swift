import DeskCore
import os
import SpriteKit

/// The desk plane and everything that leaves the hand (M7; DESIGN §2.1 fling, §2.2 E7, E8, E11, §4.6–§4.7): the
/// `DeskPlaneWorld` and its `PileBodies`, the `TossAnimator`, and the elements that live on them (loose piles, floor
/// tokens, the pen cup, the wastebasket, the apron's knock). It owns the rules for where things land:
///
/// - **releases** (`release`, called by `CarrySession` before its own drop): a release over the bare desk, one faster
///   than 250 px/s (`Ballistics.Params.frontFlingSpeed`) over no affordance, or one below the desk's front edge
///   leaves the hand on a `Ballistics` arc from the stack's base (`Ballistics.release`): over the desk (or the wall
///   above it) it lands on the desk and slides on with part of the hand's speed, so a hard flick slides off the edge;
///   below the front edge (or flicked down over it) it flies in the plane just in front of the desk to the floor or
///   the basket. A gentle drop at the basket's mouth hops in. Affordances (screen, containers, bonks) keep the carry's
///   own drop; a bonk on the pen cup pops below the monitor's chin;
/// - **landings**: on the desk a pile (joining one within `joinRadius`, else a new body at the nearest free spot, the
///   hand's velocity handed over, the token led by the hand on top), on the floor a stack at `FloorLine` x, in the
///   basket a ball (SWISH! for a clean pass; a full basket bonks it out beside itself). A flight lands only the tokens
///   still where they took off from (an undo, Take Everything Out or a Finder change in the meantime wins). Carries
///   commit with journaled actions (`dropOnDesk`, `dropOnFloor`, `move`); motion the scene started on its own
///   (push-offs, spills) commits with `settle`;
/// - **after each physics step** (`didSimulate`): rest commits (`pilesSettled`), push-offs, watchdog snaps;
/// - the **knock** (`knock`), and **hard sleep** (`settle`): flights land, bodies freeze, positions commit.
final class PhysicsHub {
    unowned let context: SceneContext
    let world = DeskPlaneWorld()
    let bodies: PileBodies
    let tosses: TossAnimator
    private(set) lazy var piles = DeskPilesElement(hub: self)
    private(set) lazy var floor = FloorElement(hub: self)
    private(set) lazy var cup = PenCupElement(hub: self)
    private(set) lazy var basket = WastebasketElement(hub: self)
    private(set) lazy var apron = ApronElement(hub: self)
    /// The latest input event's time (rim-drag speeds, the knock's cooldown).
    var eventTime: () -> Double = { 0 }
    /// Installed elements that take knocks.
    var knockables: () -> [any Knockable] = { [] }
    /// Hides the room's static cup and basket sprites (after every rebuild of the room).
    var hidePlacements: () -> Void = {}
    /// Core x of the chair's left edge where it is now (new floor landings keep clear of its base).
    var chairLeft: () -> Float = { Float(CoreLayout.chair.x) }
    /// The drawers' live sims, so a knock leaves a held or chomping drawer alone (`DeskKnock.plan(drawers:)`).
    var drawerSims: () -> [ContainerID: DrawerSim] = { [:] }
    private var knocker = DeskKnock()
    /// Desk knocks so far (the cooldown drops double-clicks that come too soon).
    private(set) var knocks = 0
    private var seedCounter: UInt64 = 0
    /// Carries in the air and their flights.
    private var carryFlights: [ObjectIdentifier: (carry: CarrySession, flight: TossAnimator.Flight)] = [:]
    /// Spilled pens still to leave the lying cup, and the seconds until the next one.
    private var pendingPens: (spills: [PenCupMachine.Spill], keys: [TokenKey], wait: Double)?
    /// The hidden keys the bodies were last synced with (a carry taken from a pile leaves it without a body).
    private var syncedHidden: Set<TokenKey> = []
    /// A carry's tokens while its landing commits (still in the hand's set until the carry finishes).
    private var landing: Set<TokenKey> = []
    // MARK: mat
    /// The desk mat's say over the plane (DESIGN §2.2 E9, §4.7; `RoomContent+Mat`): a pile it covers has no body; a
    /// pile under lifted cloth is drawn in the mat's raster, not by `piles`; a landing on the mat tucks under it (the
    /// spot it rests at, and the covered pile within reach it joins).
    var isUnderMat: (PileID) -> Bool = { _ in false }
    var drawnByMat: (PileID) -> Bool = { _ in false }
    /// The pop-up frame (0, 1) of a pile the cloth has just come off, nil at full height.
    var revealPop: (PileID) -> Int? = { _ in nil }
    var matLanding: (SIMD2<Float>, Int) -> (pile: PileID?, at: SIMD2<Float>)? = { _, _ in nil }

    /// Within this distance (plane px) a landing joins a pile instead of starting one: about a pile's width, so two
    /// stacks never stand half over each other.
    static let joinRadius: Float = 15
    /// Seconds between pens leaving the cup, and between balls leaving the basket.
    static let penInterval = 0.08
    static let ballInterval = 0.05
    static let log = Logger(subsystem: "io.github.deskterior", category: "physics")

    init(context: SceneContext) {
        self.context = context
        bodies = PileBodies(world: world)
        tosses = TossAnimator(context: context, z: CGFloat(RoomLayer.underDesk.rawValue * 1000 + 900))
        tosses.onRim = { [unowned self] p in basket.rimHit(at: p) }
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
    /// nothing); floor stacks and the chair's base are stepped over; a put-away cabinet leaves its span free.
    var ballistics: Ballistics.Params {
        var p = Ballistics.Params.standard
        guard let s = state else { return p }
        p.floorAvoid = FloorLine.furniture(basket: s.wastebasket, stowed: s.stowed) + [FloorLine.chair(at: chairLeft())]
            + FloorLine.spans(floorCentres(s))
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

    /// Tokens hidden from the desk, floor and containers: in hand or in the air (not the ones landing right now).
    var hiddenKeys: Set<TokenKey> {
        (context.screen?.carried ?? []).union(tosses.flyingKeys).subtracting(landing)
    }

    // MARK: Model

    /// Follows the model (the piles element calls this first on every apply).
    func apply(_ s: DeskState) {
        world.attach(to: world.root.scene)
        world.setFurniture("keyboard", DeskPlaneWorld.keyboardFootprint(s.mat.keyboard))
        // MARK: tidy (0.3.0): a put-away plant's or phone stand's footprint leaves the plane (Erratum 30); the
        // reducer has already moved aside the piles where a returning one stands.
        if s.stowed != bodies.stowed {
            world.setFootprints(stowed: s.stowed)
            bodies.stowed = s.stowed
        }
        syncBodies(s)
    }

    /// Bodies for the piles holding tokens on show: a pile whose tokens are all in hand or in the air has none
    /// (DESIGN §2.1: a carry has no body), and gets it back where the model holds it when they come home.
    func syncBodies(_ s: DeskState? = nil) {
        guard let s = s ?? state else { return }
        let hidden = hiddenKeys
        let inAir = tosses.flyingKeys
        syncedHidden = hidden
        var shown: [PileID: SIMD2<Float>] = [:]
        var flying = Set<PileID>()
        for (id, p) in s.piles {
            let members = s.tokens.members(of: id)
            if members.contains(where: inAir.contains) { flying.insert(id) }
            if members.contains(where: { !hidden.contains($0) }), !isUnderMat(id) { shown[id] = p }  // MARK: mat
        }
        bodies.sync(shown, obstacles: obstacles, flying: flying)
    }

    /// Where each of `keys` is now (a flight lands only the tokens still there when it comes down).
    func whereNow(_ keys: [TokenKey]) -> [TokenKey: Location] {
        guard let s = state else { return [:] }
        var out: [TokenKey: Location] = [:]
        for k in keys { out[k] = s.tokens.location(of: s.currentKey(for: k)) }
        return out
    }

    /// `keys` (by their current names) that still exist and, with `origins`, are still in the same place (the same
    /// pile, container, screen cell or floor spot) as when their flight took off.
    func unmoved(_ keys: [TokenKey], since origins: [TokenKey: Location]?) -> [TokenKey] {
        guard let s = state else { return [] }
        return keys.compactMap { k in
            let now = s.currentKey(for: k)
            guard let loc = s.tokens.location(of: now) else { return nil }
            if let origins, let was = origins[k], !Self.samePlace(loc, was) { return nil }
            return now
        }
    }

    /// The same pile or container (whatever the order), else the same location.
    static func samePlace(_ a: Location, _ b: Location) -> Bool {
        if let p = a.pile { return p == b.pile }
        if let c = a.container { return c == b.container }
        return a == b
    }

    // MARK: Releases

    /// A carry let go at canvas `p` with `velocity` (canvas px/s): true when the hub takes it (it flies, and the
    /// carry waits in `.flying` for `landed()`; or it bonked on the pen cup). Bonks make the cup or the basket wobble.
    func release(_ carry: CarrySession, at p: SIMD2<Float>, velocity: SIMD2<Float>) -> Bool {
        guard let s = state else { return false }
        let r = carry.verdict
        if case let .bonk(reason)? = r?.verdict {
            if r?.element == cup.id {
                bonkOnCup(reason)
                carry.cancelled()
                return true
            }
            if r?.element == basket.id { basket.bonked() }
            return false
        }
        let keys = carry.keys.map(s.currentKey).filter(s.tokens.contains)
        guard !keys.isEmpty else { return false }
        let origins = whereNow(keys)
        let base = carry.basePoint(at: p)
        if let r, r.element == basket.id, case .accept = r.verdict {
            // A gentle drop at the mouth: it hops in.
            let to = SIMD2(TossAnimator.mouth.x, TossAnimator.mouth.y + 3)
            let from = core(base)
            let path = TossAnimator.Path.hop(from: from, to: to, height: 6, duration: 0.18)
            fly(carry, keys: keys, path: path, crumples: true, squash: 0) { [unowned self] _ in
                landInBasket(keys, toss: nil, from: to, journaled: true, origins: origins)
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
        fly(carry, keys: keys, path: .toss(toss), crumples: toss.isIn || toss.rimHits > 0,
            squash: Self.squashAmount(toss)) { [unowned self] _ in
            land(keys, toss: toss, journaled: true, origins: origins)
        }
        return true
    }

    /// A drop the pen cup refuses: BONK (below the monitor's chin, so it stays readable), a shake, the toast, and
    /// the cup wobbles; the carry springs back.
    private func bonkOnCup(_ reason: ToastKey?) {
        let r = cup.bounds
        let chin = context.layout.rect(CoreLayout.chin).maxY
        let text = FXArt.pop(.bonk).image.height
        context.fx.pop(.bonk, at: ArtPoint(r.midX, max(r.minY, chin + text + 8)))
        context.shake(frames: 2)
        if let reason { context.toast(reason) }
        context.bonks += 1
        cup.bonked()
    }

    /// How hard a toss lands (`PileArt.squash` amount): none for a set-down (or into the basket), a little for a
    /// short drop, fully for a fall or a throw.
    static func squashAmount(_ toss: Ballistics.Toss) -> Int {
        toss.isIn ? 0 : squashAmount(impact: abs(toss.velocity(at: max(0, toss.duration - 1e-3)).z))
    }

    static func squashAmount(impact: Float) -> Int {
        impact < 120 ? 0 : (impact < 300 ? 1 : 2)
    }

    private func fly(_ carry: CarrySession, keys: [TokenKey], path: TossAnimator.Path, crumples: Bool, squash: Int,
                     land: @escaping (TossAnimator.Flight) -> Void) {
        carry.handOff()
        let stack = flightImage(keys)
        let id = ObjectIdentifier(carry)
        let flight = tosses.launch(keys, path: path, image: stack.image, base: stack.base, crumples: crumples,
                                   squash: squash) { [unowned self] f in
            carryFlights[id] = nil
            landing = Set(f.keys)
            land(f)
            landing = []
            carry.landed()
        }
        carryFlights[id] = (carry, flight)
        syncBodies()
    }

    /// A carry cut short in the air (hard sleep, teardown): it lands now.
    func landNow(_ carry: CarrySession) {
        guard let f = carryFlights[ObjectIdentifier(carry)]?.flight else { return }
        tosses.land(f)
    }

    /// The stack image a flight shows (no shadow while airborne). `keys` are front first: a carry's lead, a pile's top.
    func flightImage(_ keys: [TokenKey]) -> PileArt.Stack {
        let icons = keys.prefix(PileArt.maxIcons).compactMap { k in
            state?.tokens.meta(of: k).map { TokenArt.icon(k, $0, context) }
        }
        return PileArt.stack(Array(icons), count: keys.count, shadow: nil)
    }

    // MARK: Landings

    /// Where a toss of `keys` (front first) ended: commit it (journaled for a carry, `settle` for motion the scene
    /// started), for the tokens still where they were at `origins`.
    func land(_ keys: [TokenKey], toss: Ballistics.Toss, journaled: Bool, origins: [TokenKey: Location]? = nil) {
        switch toss.landing {
        case let .desk(point):
            // MARK: harden: with Reduce Motion a toss is set down where it lands, with no slide after.
            let v = context.reduceMotion ? .zero : toss.landingVelocity
            landOnDesk(keys, at: point, velocity: SIMD2(v.x, v.y), journaled: journaled, origins: origins)
        case let .floor(x):
            let end = toss.projection.project(toss.end)
            if toss.end.y > 1 {
                // Down beside the desk, behind the front floor line: it hops forward onto the line.
                let to = SIMD2(x, Float(CoreLayout.floorY))
                let stack = flightImage(keys)
                tosses.launch(keys, path: .hop(from: end, to: to, height: 4, duration: 0.14), image: stack.image,
                              base: stack.base, squash: 0) { [unowned self] _ in
                    landOnFloor(keys, x: Int(x.rounded()), journaled: journaled, origins: origins)
                }
            } else {
                landOnFloor(keys, x: Int(x.rounded()), journaled: journaled, origins: origins)
            }
        case .basket:
            landInBasket(keys, toss: toss, from: toss.projection.project(toss.end), journaled: journaled,
                         origins: origins)
        }
    }

    /// On the floor at `x`: the tokens stand there together as one floor stack.
    func landOnFloor(_ keys: [TokenKey], x: Int, journaled: Bool, origins: [TokenKey: Location]? = nil) {
        let live = unmoved(keys, since: origins)
        guard !live.isEmpty else { return }
        context.fx.puff(at: context.layout.point(ArtPoint(x, CoreLayout.floorY)))
        if journaled {
            dispatch(.dropOnFloor(live, x: x))
        } else {
            dispatch(.settle(SettleReport(moves: live.map { .init(key: $0, to: .floor(x: x)) })))
        }
    }

    /// Into the basket: SWISH! for a clean toss; a basket that cannot take them all bonks them out onto the floor
    /// beside it.
    func landInBasket(_ keys: [TokenKey], toss: Ballistics.Toss?, from: SIMD2<Float>, journaled: Bool,
                      origins: [TokenKey: Location]? = nil) {
        guard let s = state else { return }
        let live = unmoved(keys, since: origins)
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
            let back = whereNow(live)
            tosses.launch(live, path: .hop(from: from, to: SIMD2(Float(spot), Float(CoreLayout.floorY)), height: 14,
                                          duration: 0.3),
                          image: stack.image, base: stack.base, squash: 1) { [unowned self] _ in
                landOnFloor(live, x: spot, journaled: journaled, origins: back)
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
    /// the nearest free spot with `velocity` (plane px/s). `keys` are front first: the first ends on top.
    func landOnDesk(_ keys: [TokenKey], at aim: SIMD2<Float>, velocity: SIMD2<Float>, journaled: Bool,
                    origins: [TokenKey: Location]? = nil) {
        guard let s = state else { return }
        let live = unmoved(keys, since: origins)
        guard !live.isEmpty else { return }
        // MARK: mat
        // Joining a covered pile slides it in as far as its taller bump needs, in the same journaled move.
        let tuck = matLanding(aim, live.count)
        if let tuck, let id = tuck.pile, let at = s.piles[id] {
            if journaled && tuck.at != at {
                dispatch(.tuckUnderMat(Array(live.reversed()), pile: id, at: tuck.at))
            } else {
                commitDesk(live, pile: id, at: tuck.at, journaled: journaled)
            }
            return
        }
        let point = tuck?.at ?? aim
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

    /// Puts `keys` (front first) on `pile`, the first on top.
    private func commitDesk(_ front: [TokenKey], pile: PileID, at: SIMD2<Float>, journaled: Bool) {
        let keys = Array(front.reversed())
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
        tosses.needsFrames || bodies.isMoving || pendingPens != nil || hiddenKeys != syncedHidden
    }

    /// One fixed step before the physics (the piles element runs it): flights, spilling pens, and bodies for piles
    /// whose tokens left the hand or came back to it.
    func step(_ dt: Double) {
        world.attach(to: world.root.scene)
        tosses.step(dt)
        stepPens(dt)
        if hiddenKeys != syncedHidden { syncBodies() }
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
            // Top first, as the pile shows them.
            let keys = Array(s.tokens.members(of: id).filter { !hiddenKeys.contains($0) }.reversed())
            guard !keys.isEmpty else {
                // Nothing on show to fly (all in hand): the pile goes back on the desk.
                bodies.unlaunch(id, near: at, committedAt: s.piles[id], obstacles: obstacles)
                continue
            }
            let toss = Ballistics.pushOff(at: at, velocity: v, params: ballistics)
            let stack = flightImage(keys)
            let origins = whereNow(keys)
            tosses.launch(keys, path: .toss(toss), image: stack.image, base: stack.base,
                          crumples: toss.isIn || toss.rimHits > 0, squash: Self.squashAmount(toss)) { [unowned self] _ in
                land(keys, toss: toss, journaled: false, origins: origins)
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
    func spillPens(right: Bool, from position: SIMD2<Float>, direction: SIMD2<Float>? = nil) {
        guard let s = state else { return }
        let keys = s.tokens.members(of: .penCup).filter { !hiddenKeys.contains($0) }
        guard !keys.isEmpty else { return }
        let spills = PenCupMachine.spill(count: keys.count, from: position, right: right, seed: nextSeed(),
                                         direction: direction, ballistics: ballistics)
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
        let spots = WastebasketMachine.spillSpots(count: keys.count, right: right,
                                                  avoiding: [FloorLine.chair(at: chairLeft())]
                                                      + FloorLine.spans(floorCentres(s)))
        let origins = whereNow(keys)
        let lying = WastebasketMachine.tippedRect(right: right)
        let mouth = SIMD2(Float(right ? lying.maxX - 3 : lying.minX + 3), Float(lying.midY + 4))
        for (i, (key, spot)) in zip(keys, spots).enumerated().reversed() {
            let to = SIMD2(Float(spot), Float(CoreLayout.floorY))
            // The top ball first; each one after waits its turn in the mouth.
            let rank = keys.count - 1 - i
            let duration = 0.18 + abs(to.x - mouth.x) / 500
            let icon = flightImage([key])
            tosses.launch([key], path: .hop(from: mouth, to: to, height: 8 + Float(rank % 3) * 3, duration: duration),
                          image: icon.image, base: icon.base, crumples: false, squash: 1,
                          delay: Float(rank) * Float(Self.ballInterval), look: .ball) { [unowned self] _ in
                landOnFloor([key], x: spot, journaled: false, origins: origins)
            }
        }
    }

    // MARK: Knock

    /// A desk knock from the apron at core x `x` (1 s cooldown): piles and floor tokens hop, props wobble, ajar
    /// drawers snap shut. Membership never changes.
    func knock(atCoreX x: Float) {
        guard let s = state else { return }
        let origin = SIMD2(x, 0)
        guard var plan = knocker.knock(s, drawers: drawerSims(), at: eventTime(), origin: origin, seed: nextSeed())
        else { return }
        // MARK: harden: Reduce Motion keeps the knock's one change (ajar drawers shut) and drops its hops and wobbles.
        if context.reduceMotion { plan = plan.stilled }
        knocks += 1
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
