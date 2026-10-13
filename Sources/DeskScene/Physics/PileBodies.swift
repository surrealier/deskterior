import DeskCore

/// The loose piles' bodies from frame to frame (DESIGN §4.7, §2.2 E11), over `DeskPlaneWorld`:
///
/// - **sync** follows the model: a pile without a body gets one (restored piles start frozen); a pile the model moved
///   on its own (undo, a relaunch) gets a new body there; a pile the model dropped loses its body;
/// - **after each physics step** it clamps speeds to 1200 px/s, sends piles whose centre crossed the desk's front,
///   left or right edge off on an arc (the back is a wall), lets the `PileWatchdog` snap piles that went NaN, left the
///   desk or stayed awake over 10 s, reports piles that came to rest since they last moved (the scene commits them
///   with one `pilesSettled`), and runs the `PileFreezer`: 2 s at rest freezes a body to static; a moving pile thaws
///   the frozen ones near it; at most 120 stay dynamic.
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
    /// Bodies that moved since they last came to rest.
    private(set) var unsettled: Set<PileID> = []
    /// Speed (plane px/s) above which a pile thaws frozen piles near it.
    static let thawSpeed: Float = 4

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

    /// Adopts the model's pile positions (only piles holding tokens on show; covered piles have no body).
    func sync(_ piles: [PileID: SIMD2<Float>]) {
        var restored = Set<PileID>()
        for id in piles.keys.sorted() where !launched.contains(id) {
            let pos = piles[id]!
            if world.piles[id] == nil {
                world.addPile(id, at: pos, dynamic: false)
                restored.insert(id)
            } else if committed[id] != pos {
                // The model moved it (undo, a relaunch): a new body there, at rest.
                world.addPile(id, at: pos, dynamic: false)
                restored.insert(id)
                unsettled.remove(id)
                _ = freezer.sync(Set(world.piles.keys).subtracting([id]))
            }
            committed[id] = pos
        }
        for id in ids where piles[id] == nil { drop(id) }
        launched.formIntersection(piles.keys)
        apply(freezer.sync(Set(world.piles.keys), startFrozen: restored))
        watchdog.retain(Set(world.piles.keys))
    }

    /// A pile the scene makes (a landing, a spill): its body starts at `p` with `velocity`; the scene commits it to the
    /// model in the same turn.
    func add(_ id: PileID, at p: SIMD2<Float>, velocity: SIMD2<Float> = .zero) {
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
        for id in ids {
            guard let p = world.position(of: id) else { continue }
            var v = world.velocity(of: id)
            let clamped = DeskPlanePhysics.clampPileVelocity(v)
            if clamped != v {
                world.setVelocity(id, clamped)
                v = clamped
            }
            if p.isFinite, p.y < desk.d || p.x < desk.x || p.x > desk.x + desk.width {
                report.pushedOff.append((id, p, v))
                continue
            }
            let speed = (v * v).sum().squareRoot()
            live[id] = p
            if world.isDynamic(id) { speeds[id] = speed }
            if speed >= freezer.params.restSpeed { unsettled.insert(id) }
            if speed >= Self.thawSpeed, p.isFinite { moving.append(p) }
        }
        for (id, _, _) in report.pushedOff { launch(id) }

        // The watchdog: NaN, off the desk, awake too long.
        for id in live.keys.sorted() {
            let p = live[id]!
            let others = live.filter { $0.key != id }.map(\.value)
            let awake = (speeds[id] ?? 0) >= freezer.params.restSpeed
            switch watchdog.check(id, position: p, isAwake: awake, dt: dt, others: others, obstacles: obstacles) {
            case .ok:
                break
            case let .snap(spot, reason):
                world.addPile(id, at: spot, dynamic: true)
                live[id] = spot
                unsettled.remove(id)
                report.settled[id] = spot
                report.snapped.append((id, reason))
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

        // Freezer: rest timers, then thaw what moving piles come near.
        apply(freezer.update(speeds: speeds, dt: dt))
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
