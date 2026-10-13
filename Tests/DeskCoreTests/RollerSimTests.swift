import Testing
@testable import DeskCore

@Suite("RollerSim")
struct RollerSimTests {
    static let dt: Float = 1.0 / 60

    static func run(_ sim: inout RollerSim, frames: Int = 1200) -> [RollerSim.Event] {
        var events: [RollerSim.Event] = []
        for _ in 0..<frames where sim.needsFrames { events += sim.step(dt) }
        return events
    }

    @Test("Starts clamped to the travel (errata 7: 64…432) and reads the persisted state")
    func initial() {
        #expect(RollerSim(x: 10).x == 64)
        #expect(RollerSim(x: 999).x == 432)
        #expect(RollerSim(x: .nan).x == Float(CoreLayout.chair.x))
        let s = RollerSim(ChairState(x: 300, facing: 7))
        #expect(s.x == 300 && s.facing == 3 && s.chairFacing == .left)
        #expect(s.state == ChairState(x: 300, facing: 3))
    }

    @Test("A release keeps 60% of the fling, coasts with friction and settles once on whole px")
    func releaseAndCoast() {
        var sim = RollerSim(x: 196)
        sim.beginDrag(pointerX: 230)
        sim.drag(pointerX: 230)
        _ = sim.step(Self.dt)
        sim.endDrag(releaseVelocity: 100)
        #expect(abs(sim.v - 60) < 0.001)
        let events = Self.run(&sim)
        let settles = events.compactMap { if case let .settled(x, f) = $0 { (x, f) } else { nil } }
        #expect(settles.count == 1)
        #expect(sim.x > 196 && sim.x < 196 + 60 / sim.params.friction)
        #expect(sim.x == sim.x.rounded() && sim.isAsleep)
        #expect(settles.first?.1 == 0, "too slow to spin")
    }

    @Test("Ends bounce with restitution 0.3; a fast fling spins through the facings and lands on a frame")
    func bounceAndSpin() {
        var sim = RollerSim(x: 300)
        sim.beginDrag(pointerX: 300)
        sim.endDrag(releaseVelocity: 1200)
        var events: [RollerSim.Event] = []
        var facings = Set<Int>()
        var bounceSpeedOut: Float?
        while sim.needsFrames {
            let before = sim.v
            let e = sim.step(Self.dt)
            if e.contains(where: { if case .bump = $0 { true } else { false } }) {
                bounceSpeedOut = -sim.v / before
            }
            events += e
            facings.insert(sim.facing)
        }
        #expect(events.contains { if case .bump(_, 1) = $0 { true } else { false } })
        if let r = bounceSpeedOut { #expect(abs(r - sim.params.restitution) < 0.05) }
        #expect(facings.count == 4)
        #expect(sim.spin == sim.spin.rounded())
        #expect(sim.x >= 64 && sim.x <= 432)
    }

    @Test("An open cabinet drawer blocks the chair; a drawer thunk pushes it clear of the block")
    func cabinetBlock() {
        let blockX = RollerSim.cabinetBlockX()
        #expect(blockX == 336)
        var sim = RollerSim(x: 300)
        sim.setBlock(blockX)
        sim.beginDrag(pointerX: 300)
        sim.endDrag(releaseVelocity: 800)
        let events = Self.run(&sim)
        #expect(events.contains { if case .blockedByDrawer = $0 { true } else { false } })
        #expect(sim.x <= blockX)

        for start: Float in [340, 380, 400, 432] {
            var chair = RollerSim(x: start)
            #expect(DrawerSim.cabinetOpenLimit(travel: 12, chairX: chair.x) == 3)
            chair.pushedByDrawer()
            _ = Self.run(&chair)
            #expect(DrawerSim.cabinetOpenLimit(travel: 12, chairX: chair.x) == 12, "pushed from \(start) to \(chair.x)")
        }
    }

    @Test("Coast distance model matches the stepped sim within a few px")
    func coastModel() {
        let sim = RollerSim()
        for v0: Float in [60, 150, 400] {
            var s = RollerSim(x: 64)
            s.push(v0)
            _ = Self.run(&s)
            #expect(abs((s.x - 64) - sim.coastDistance(v0)) < 4, "v0 \(v0)")
        }
        #expect(abs(sim.coastDistance(sim.speedToCoast(80)) - 80) < 0.01)
    }

    @Test("Random drags, flings and pushes stay in the travel; two runs are identical")
    func fuzz() {
        func run(_ seed: UInt64) -> [Float] {
            var rng = SplitMix64(seed: seed)
            var sim = RollerSim(x: 200)
            var trace: [Float] = []
            for _ in 0..<4000 {
                switch rng.nextInt(below: 30) {
                case 0: sim.beginDrag(pointerX: sim.x + 10)
                case 1: sim.drag(pointerX: rng.nextFloat01() * 600 - 50)
                case 2: sim.endDrag(releaseVelocity: rng.nextFloat01() * 2400 - 1200)
                case 3: sim.push(rng.nextFloat01() * 400 - 200)
                case 4: sim.setBlock(rng.nextBool() ? 336 : nil)
                case 5: sim.pushedByDrawer()
                default: break
                }
                _ = sim.step(Self.dt)
                #expect(sim.x >= 64 && sim.x <= 432 && sim.v.isFinite && sim.spin.isFinite)
                trace.append(sim.x)
            }
            return trace
        }
        #expect(run(4) == run(4))
    }
}
