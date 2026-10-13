import Testing
@testable import DeskCore

@Suite("PileRest")
struct PileRestTests {
    static let dt: Float = 1.0 / 60

    static func ids(_ n: Int) -> [PileID] { (1...n).map { PileID("P\($0)") } }

    @Test("Freezer: a pile resting 2 s freezes; motion resets the timer")
    func freezesAfterRest() {
        var f = PileFreezer()
        _ = f.sync(["P1", "P2"])
        var frozenAt: [PileID: Int] = [:]
        for frame in 0..<200 {
            let speeds: [PileID: Float] = ["P1": 0.1, "P2": frame < 60 ? 5 : 0]
            for p in f.update(speeds: speeds, dt: Self.dt).freeze { frozenAt[p] = frame }
        }
        #expect((118...120).contains(frozenAt["P1"] ?? -1), "2 s at 60 fps")
        #expect((178...180).contains(frozenAt["P2"] ?? -1), "2 s after it stopped")
        #expect(f.isFrozen("P1") && f.dynamicCount == 0)
    }

    @Test("Freezer: at most 120 dynamic bodies; the longest-resting freeze first")
    func budget() {
        var f = PileFreezer()
        let all = Set(Self.ids(200))
        let changes = f.sync(all)
        #expect(f.dynamicCount == 120 && changes.freeze.count == 80)
        // A drag thaws its pile even at the budget; another freezes instead.
        let frozen = all.subtracting(f.dynamic).sorted()[0]
        let drag = f.thaw(frozen)
        #expect(drag.thaw == [frozen] && drag.freeze.count == 1 && f.dynamicCount == 120)
        #expect(!f.isFrozen(frozen))
    }

    @Test("Freezer: thaws near a brush nearest-first within the budget; knocks thaw all; hard sleep freezes all")
    func thawRules() {
        var f = PileFreezer(params: { var p = PileFreezer.Params(); p.maxDynamic = 2; return p }())
        let positions: [PileID: SIMD2<Float>] = ["P1": [100, 50], "P2": [110, 50], "P3": [130, 50], "P4": [400, 50]]
        _ = f.sync(Set(positions.keys), startFrozen: Set(positions.keys))
        #expect(f.dynamicCount == 0)
        let near = f.thaw(near: [104, 50], positions: positions)
        #expect(near.thaw == ["P1", "P2"], "nearest first, two fit the budget")
        _ = f.freezeAll()
        let knock = f.thawAll(from: [420, 50], positions: positions)
        #expect(knock.thaw == ["P4", "P3"])
        let sleep = f.freezeAll()
        #expect(Set(sleep.freeze) == ["P3", "P4"] && f.dynamicCount == 0)
        // Gone piles are forgotten.
        _ = f.sync(["P1"])
        #expect(f.frozen == ["P1"])
    }

    @Test("Watchdog: NaN snaps to the last good spot; out of bounds snaps inside; awake > 10 s snaps in place")
    func watchdog() {
        var w = PileWatchdog()
        let fine = w.check("P1", position: [200, 50], isAwake: true, dt: Self.dt) == .ok
        #expect(fine)
        if case let .snap(to, reason) = w.check("P1", position: [.nan, 3], isAwake: true, dt: Self.dt) {
            #expect(reason == .notFinite && to == [200, 50])
        } else {
            Issue.record("expected a snap")
        }
        if case let .snap(to, reason) = w.check("P2", position: [600, -40], isAwake: true, dt: Self.dt) {
            #expect(reason == .outOfBounds && w.inBounds(to))
            #expect(to == [493, 5], "nearest in-bounds spot")
        } else {
            Issue.record("expected a snap")
        }
        var verdict = PileWatchdog.Verdict.ok
        var frames = 0
        while verdict == .ok && frames < 2000 {
            verdict = w.check("P3", position: [300, 60], isAwake: true, dt: Self.dt)
            frames += 1
        }
        #expect(verdict == .snap(to: [300, 60], reason: .awakeTooLong))
        #expect((600...602).contains(frames), "10 s at 60 fps")
        // Resting resets the awake timer.
        for _ in 0..<500 { _ = w.check("P4", position: [300, 60], isAwake: true, dt: Self.dt) }
        let resting = w.check("P4", position: [300, 60], isAwake: false, dt: Self.dt) == .ok
        #expect(resting)
        #expect(w.awake["P4"] == 0)
    }

    @Test("Valid spots avoid furniture footprints, obstacles and other piles; a full desk sends piles to the monitor")
    func spots() {
        let w = PileWatchdog()
        let riser = DeskPlanePhysics.footprints["riser"]!
        let inRiser = SIMD2<Float>(riser.center.x, riser.center.y)
        let spot = w.nearestValidSpot(to: inRiser, others: [])!
        #expect(w.isValidSpot(spot, others: []))
        #expect(spot.y < 112 && abs(spot.x - inRiser.x) <= 1)
        let other = SIMD2<Float>(250, 60)
        let beside = w.nearestValidSpot(to: other, others: [other])!
        #expect(!DeskPlaneRect.centred(at: beside, size: DeskPlanePhysics.pileSize)
            .intersects(DeskPlaneRect.centred(at: other, size: DeskPlanePhysics.pileSize)))
        let cup = DeskPlanePhysics.penCupFootprint(at: [250, 60])
        #expect(!w.isValidSpot([250, 62], others: [], obstacles: [cup]))
        // Fill the desk with piles on a 14×10 lattice: nowhere is left.
        var crowd: [SIMD2<Float>] = []
        for x in stride(from: Float(19), through: 493, by: 14) {
            for d in stride(from: Float(5), through: 123, by: 10) { crowd.append([x, d]) }
        }
        var full = PileWatchdog()
        #expect(full.nearestValidSpot(to: [250, 60], others: crowd) == nil)
        let verdict = full.check("PX", position: [.nan, .nan], isAwake: true, dt: Self.dt, others: crowd)
        let sentToMonitor = verdict == .toMonitor(reason: .notFinite)
        #expect(sentToMonitor)
    }

    @Test("Physics categories (§12)")
    func categories() {
        #expect(PhysicsCategory.furniture.rawValue == 1 && PhysicsCategory.pile.rawValue == 2
            && PhysicsCategory.prop.rawValue == 4)
        #expect(PhysicsCategory.pile.collisionMask == [.furniture, .pile, .prop])
        #expect(PhysicsCategory.prop.collisionMask == [.furniture, .pile])
        #expect(PhysicsCategory.furniture.collisionMask.isEmpty)
        #expect(PhysicsCategory.reserved.intersection([.furniture, .pile, .prop]).isEmpty)
        #expect(PhysicsCategory.contactTestMask == 0)
        let v = DeskPlanePhysics.propDrive(from: [0, 0], to: [100, 0], dt: Self.dt)
        #expect(v == [600, 0])
        #expect(abs(DeskPlanePhysics.propDrive(from: [0, 0], to: [1, 0], dt: Self.dt).x - 30) < 0.001)
        let c = DeskPlanePhysics.clampPileVelocity([3000, 4000])
        #expect(abs(c.x - 720) < 0.01 && abs(c.y - 960) < 0.01)
        #expect(DeskPlanePhysics.clampPileVelocity([.nan, 1]) == .zero)
        for f in DeskPlanePhysics.footprints.values { #expect(f.d == 112 && f.d + f.depth == 128) }
    }
}
