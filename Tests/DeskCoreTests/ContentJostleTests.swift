import Testing
@testable import DeskCore

@Suite("ContentJostle")
struct ContentJostleTests {
    static let dt: Float = 1.0 / 60
    static let bounds: ClosedRange<Float> = 3...8

    static func jostle(_ n: Int = 5, seed: UInt64 = 1) -> ContentJostle {
        ContentJostle(homes: (0..<n).map { 8 - Float($0 % 2) }, bounds: bounds, seed: seed)
    }

    @Test("Random drawer accelerations never push an item outside the interior")
    func bounded() {
        var rng = SplitMix64(seed: 5)
        var j = Self.jostle(8)
        for _ in 0..<5000 {
            let a = (rng.nextFloat01() * 2 - 1) * (rng.nextBool(probability: 0.1) ? 40_000 : 3000)
            j.step(drawerAcceleration: a, Self.dt)
            for (p, v) in zip(j.positions, j.velocities) {
                #expect(Self.bounds.contains(p) && v.isFinite)
                #expect(abs(v) <= j.params.maxSpeed)
            }
        }
        j.step(drawerAcceleration: .nan, Self.dt)
        j.step(drawerAcceleration: .infinity, Self.dt)
        #expect(j.positions.allSatisfy { Self.bounds.contains($0) })
    }

    @Test("A slam throws the contents to the back; they come home and the jostle sleeps")
    func slamAndSleep() {
        var j = Self.jostle()
        // A closing drawer stopped dead in one frame: +150 px/s of velocity change.
        j.step(drawerAcceleration: 150 / Self.dt, Self.dt)
        var minOffset = 0
        for _ in 0..<10 {
            j.step(drawerAcceleration: 0, Self.dt)
            minOffset = min(minOffset, j.pixelOffsets.min() ?? 0)
        }
        #expect(minOffset <= -3, "items slid toward the back")
        for _ in 0..<600 where j.needsFrames { j.step(drawerAcceleration: 0, Self.dt) }
        #expect(j.isAsleep)
        #expect(j.positions == j.homes && j.pixelOffsets.allSatisfy { $0 == 0 })
    }

    @Test("A gently drawn drawer leaves its contents in place (static friction)")
    func stiction() {
        var j = Self.jostle()
        for _ in 0..<60 { j.step(drawerAcceleration: 300, Self.dt) }
        #expect(j.isAsleep && j.pixelOffsets.allSatisfy { $0 == 0 })
    }

    @Test("Deterministic for a seed; items move out of step")
    func deterministic() {
        func run(_ seed: UInt64) -> [[Float]] {
            var j = Self.jostle(6, seed: seed)
            var out: [[Float]] = []
            for f in 0..<90 {
                j.step(drawerAcceleration: f < 5 ? 6000 : (f == 20 ? -9000 : 0), Self.dt)
                out.append(j.positions)
            }
            return out
        }
        let a = run(3)
        #expect(a == run(3))
        #expect(a.contains { Set($0).count > 2 }, "per-item springs differ")
    }

    @Test("Knocks kick items; new homes keep existing motion and clamp")
    func knockAndHomes() {
        var j = Self.jostle(4)
        j.knock(strength: 1, seed: 11)
        #expect(!j.isAsleep && j.velocities.allSatisfy { abs($0) >= j.params.knockKick.lowerBound - 0.01 })
        j.step(drawerAcceleration: 0, Self.dt)
        let moving = j.velocities[0]
        j.setHomes([8, 7, 8, 7, 100, .nan])
        #expect(j.count == 6 && j.velocities[0] == moving)
        #expect(j.homes[4] == 8 && j.homes[5] == 8)
        j.setHomes([])
        j.step(drawerAcceleration: 9000, Self.dt)
        #expect(j.count == 0)
    }

    @Test("Hard sleep puts every item home and stops")
    func forceRest() {
        var j = Self.jostle(6)
        j.step(drawerAcceleration: 30_000, Self.dt)
        #expect(j.needsFrames && j.pixelOffsets.contains { $0 != 0 })
        j.forceRest()
        #expect(!j.needsFrames && j.positions == j.homes && j.velocities.allSatisfy { $0 == 0 })
        j.step(drawerAcceleration: 0, Self.dt)
        #expect(!j.needsFrames)
    }
}
