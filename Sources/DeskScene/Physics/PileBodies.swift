import DeskCore

/// The loose piles' bodies from frame to frame (DESIGN §4.7, §2.2 E11), over `DeskPlaneWorld`:
///
/// - **sync** follows the model: a pile without a body gets one (restored piles start frozen); a pile the model moved
///   on its own (undo, a relaunch, a returning file) gets a new body there. A body the model would put inside
///   furniture or another pile (or off the desk) goes to the nearest free spot instead, and that spot is committed
///   on the next step, so a later knock never shoves overlapping piles apart (or off the edge). A pile the model
///   dropped, or whose tokens are all in hand or in the air, has no body (a carry has none);
/// - **after each physics step** it clamps speeds to 1200 px/s, sends piles whose centre crossed the desk's front,
///   left or right edge moving outward faster than `pushOffSpeed` off on an arc (slower ones are put back on the
///   desk; the back is a wall), lets the `PileWatchdog` snap piles that went NaN, left the desk or stayed awake over
///   10 s, reports piles that came to rest since they last moved and piles that freeze away from where the model
///   holds them (the scene commits them with one `pilesSettled`), and runs the `PileFreezer`: 2 s at rest freezes a
///   body to static; a moving pile thaws the frozen ones near it; at most 120 stay dynamic.
///
/// Positions are desk-plane `(x, d)` px. The scene dispatches; this only keeps the books.
final class PileBodies {
    struct Report {
        /// Piles that came to rest (or were snapped) and where: commit them.
        var settled: [PileID: SIMD2<Float>] = [:]
        /// Piles whose centre went over an open edge, where and how fast: they leave on an arc.
        var pushedOff: [(pile: PileID, at: SIMD2<Float>, velocity: SIMD2<Float>)] = []
        /// Piles the desk has no room for (the watchdog sends their tokens to the monitor).
        var toMonitor: [PileID] = []
        /// Watchdog snaps, for the log.
        var snapped: [(pile: PileID, reason: PileWatchdog.Reason)] = []

        var isEmpty: Bool { settled.isEmpty && pushedOff.isEmpty && toMonitor.isEmpty }
    }

    let world: DeskPlaneWorld
    private(set) var freezer = PileFreezer()
    private(set) var watchdog = PileWatchdog()
    /// Where the model holds each pile that has a body.
    private(set) var committed: [PileID: SIMD2<Float>] = [:]
    /// Piles in the air (pushed off): no body; their tokens land elsewhere.
    private(set) var launched: Set<PileID> = []
    /// Bodies that moved (or were placed somewhere new) since they last came to rest.
    private(set) var unsettled: Set<PileID> = []
    /// Speed (plane px/s) above which a pile thaws frozen piles near it.
    static let thawSpeed: Float = 4
    /// A centre over an open edge leaves the desk only moving outward at least this fast (plane px/s); slower, it
    /// was shoved there (piles pressed apart) and goes back on the desk.
    static let pushOffSpeed: Float = 12

    init(world: DeskPlaneWorld) {
        self.world = world
    }

    /// Something still moves (frames are needed).
    var isMoving: Bool { !unsettled.isEmpty }

    var ids: [PileID] { world.piles.keys.sorted() }

    /// Live body positions.
    var positions: [PileID: SIMD2<Float>] {
        var out: [PileID: SIMD2<Float>] = [:]
        for (id, _) in world.piles { out[id] = world.position(of: id) }
        return out
    }

    // MARK: Model

    /// Adopts the model's pile positions: `piles` are the piles holding tokens on show (covered piles, and piles
    /// whose tokens are all in hand or in the air, have no body). `flying` are the launched piles whose tokens are
    /// still in the air; any other launched pile gets its body back.
    func sync(_ piles: [PileID: SIMD2<Float>], obstacles: [DeskPlaneRect] = [], flying: Set<PileID>? = nil) {
        if let flying { launched.formIntersection(flying) }
        var restored = Set<PileID>(), moved = Set<PileID>()
        for id in piles.keys.sorted() where !launched.contains(id) {
            let pos = piles[id]!
            guard world.piles[id] == nil || committed[id] != pos else { continue }
            // New, or the model moved it (undo, a relaunch): a new body there at rest, or at the nearest free spot.
            if world.piles[id] != nil { moved.insert(id) }
            let others = world.piles.keys.filter { $0 != id }.compactMap(world.position(of:))
            var spot = pos
            if watchdog.isCrowded(pos, others: others, obstacles: obstacles) {
                spot = watchdog.nearestValidSpot(to: pos, others: others, obstacles: obstacles) ?? pos
            }
            world.addPile(id, at: spot, dynamic: false)
            restored.insert(id)
            committed[id] = pos
            if spot != pos { unsettled.insert(id) } else { unsettled.remove(id) }
        }
        for id in ids where piles[id] == nil { drop(id) }
        launched.formIntersection(piles.keys)
        // The freezer forgets the moved ones first, so they come back frozen with the new ones.
        if !moved.isEmpty { _ = freezer.sync(Set(world.piles.keys).subtracting(moved), startFrozen: restored) }
        apply(freezer.sync(Set(world.piles.keys), startFrozen: restored))
        watchdog.retain(Set(world.piles.keys))
    }

    /// A pile the scene makes (a landing, a spill): its body starts at `p` with `velocity`; the scene commits it to the
    /// model in the same turn.
    func add(_ id: PileID, at p: SIMD2<Float>, velocity: SIMD2<Float> = .zero) {
        launched.remove(id)
        world.addPile(id, at: p, velocity: velocity, dynamic: true)
        committed[id] = p
        unsettled.insert(id)
        apply(freezer.sync(Set(world.piles.keys)))
        apply(freezer.thaw(id))
    }

    /// The pile left the desk: no body until its tokens land.
    func launch(_ id: PileID) {
        launched.insert(id)
        world.removePile(id)
        committed[id] = nil
        unsettled.remove(id)
    }

    /// A launch that has nothing to fly (its tokens are all in hand or gone): the pile goes back on the desk at the
    /// free spot nearest `p`, at rest, and commits there.
    func unlaunch(_ id: PileID, near p: SIMD2<Float>, committedAt model: SIMD2<Float>?, obstacles: [DeskPlaneRect]) {
        launched.remove(id)
        let others = world.piles.keys.filter { $0 != id }.compactMap(world.position(of:))
        let spot = watchdog.nearestValidSpot(to: p, others: others, obstacles: obstacles) ?? model ?? p
        world.addPile(id, at: spot, dynamic: false)
        committed[id] = model
        unsettled.insert(id)
        apply(freezer.sync(Set(world.piles.keys), startFrozen: [id]))
    }

    private func drop(_ id: PileID) {
        world.removePile(id)
        committed[id] = nil
        unsettled.remove(id)
    }

    /// The model now holds `positions` (after the scene committed them).
    func didCommit(_ positions: [PileID: SIMD2<Float>]) {
        for (id, p) in positions where world.piles[id] != nil { committed[id] = p }
    }

    // MARK: Frames

    /// One step after the physics ran.
    func afterStep(_ dt: Float, obstacles: [DeskPlaneRect]) -> Report {
        var report = Report()
        let desk = DeskPlanePhysics.desk
        var speeds: [PileID: Float] = [:]
        var live: [PileID: SIMD2<Float>] = [:]
        var moving: [SIMD2<Float>] = []
        var shovedOver: [PileID] = []
        for id in ids {
            guard let p = world.position(of: id) else { continue }
            var v = world.velocity(of: id)
            let clamped = DeskPlanePhysics.clampPileVelocity(v)
            if clamped != v {
                world.setVelocity(id, clamped)
                v = clamped
            }
            if p.isFinite, p.y < desk.d || p.x < desk.x || p.x > desk.x + desk.width {
                // Outward speed over the edge(s) it crossed.
                var outward: Float = 0
                if p.y < desk.d { outward = max(outward, -v.y) }
                if p.x < desk.x { outward = max(outward, -v.x) }
                if p.x > desk.x + desk.width { outward = max(outward, v.x) }
                if outward >= Self.pushOffSpeed {
                    report.pushedOff.append((id, p, v))
                    continue
                }
                shovedOver.append(id)
            }
            let speed = (v * v).sum().squareRoot()
            live[id] = p
            if world.isDynamic(id) { speeds[id] = speed }
            if speed >= freezer.params.restSpeed { unsettled.insert(id) }
            if speed >= Self.thawSpeed, p.isFinite { moving.append(p) }
        }
        for (id, _, _) in report.pushedOff { launch(id) }

        /// The other piles' centres (built only for a pile that must move: O(n) then, not every step).
        func others(than id: PileID) -> [SIMD2<Float>] {
            live.compactMap { $0.key == id ? nil : $0.value }
        }
        func snap(_ id: PileID, to spot: SIMD2<Float>, reason: PileWatchdog.Reason) {
            world.addPile(id, at: spot, dynamic: !freezer.isFrozen(id))
            live[id] = spot
            unsettled.remove(id)
            report.settled[id] = spot
            report.snapped.append((id, reason))
        }

        // Shoved over an edge without the speed to leave: back on the desk.
        for id in shovedOver {
            guard let p = live[id] else { continue }
            if let spot = watchdog.nearestValidSpot(to: p, others: others(than: id), obstacles: obstacles) {
                snap(id, to: spot, reason: .outOfBounds)
            }
        }

        // The watchdog: NaN, off the desk, awake too long.
        for id in live.keys.sorted() {
            let p = live[id]!
            let awake = (speeds[id] ?? 0) >= freezer.params.restSpeed
            guard let reason = watchdog.problem(id, position: p, isAwake: awake, dt: dt) else { continue }
            switch watchdog.resolve(id, position: p, reason: reason, others: others(than: id), obstacles: obstacles) {
            case .ok:
                break
            case let .snap(spot, reason):
                snap(id, to: spot, reason: reason)
            case let .toMonitor(reason):
                drop(id)
                live[id] = nil
                report.toMonitor.append(id)
                report.snapped.append((id, reason))
            }
        }

        // Came to rest since it last moved: commit.
        for id in unsettled.sorted() {
            guard let p = live[id], p.isFinite else { continue }
            if world.isDynamic(id), (speeds[id] ?? 0) >= freezer.params.restSpeed { continue }
            unsettled.remove(id)
            if committed[id] != p { report.settled[id] = p }
        }

        // Freezer: rest timers, then thaw what moving piles come near. A body that freezes away from where the model
        // holds it (a slow creep, a push below the rest speed) commits where it froze.
        let changes = freezer.update(speeds: speeds, dt: dt)
        apply(changes)
        for id in changes.freeze {
            guard let p = live[id], p.isFinite, committed[id] != p, report.settled[id] == nil else { continue }
            report.settled[id] = p
        }
        for p in moving { apply(freezer.thaw(near: p, positions: live)) }
        return report
    }

    // MARK: Freezer

    /// A drag or a carried prop at `p` thaws nearby piles.
    func thaw(near p: SIMD2<Float>) {
        apply(freezer.thaw(near: p, positions: positions))
    }

    /// A knock thaws everything (nearest first, within the budget).
    func thawAll(from origin: SIMD2<Float>) {
        apply(freezer.thawAll(from: origin, positions: positions))
    }

    /// Hard sleep: every body freezes where it is; returns positions to commit.
    func freezeAll() -> [PileID: SIMD2<Float>] {
        var out: [PileID: SIMD2<Float>] = [:]
        for id in ids {
            guard let p = world.position(of: id), p.isFinite else { continue }
            if committed[id] != p { out[id] = p }
        }
        unsettled.removeAll()
        apply(freezer.freezeAll())
        return out
    }

    private func apply(_ c: PileFreezer.Changes) {
        for id in c.freeze { world.setDynamic(id, false) }
        for id in c.thaw { world.setDynamic(id, true) }
    }
}
