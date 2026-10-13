import Testing
@testable import DeskCore

/// Runs a drawer until it sleeps (or `limit` frames), collecting events.
func runDrawer(_ sim: inout DrawerSim, frames limit: Int = 600) -> [DrawerSim.Event] {
    var events: [DrawerSim.Event] = []
    for _ in 0..<limit where sim.needsFrames { events += sim.step(1.0 / 60) }
    return events
}

/// A flick toward closed: the pointer jumps past the stop and lets go at `speed`.
func flickShut(_ sim: inout DrawerSim, speed: Float = 450) -> [DrawerSim.Event] {
    sim.beginDrag()
    var events = sim.step(1.0 / 60)
    sim.drag(to: -sim.travel)
    events += sim.step(1.0 / 60)
    sim.endDrag(releaseVelocity: -speed)
    return events + runDrawer(&sim)
}

@Suite("DrawerSim")
struct DrawerSimTests {
    static let dt: Float = 1.0 / 60

    @Test("Jam gap = min(6, max(0, n − capacity)) for every drawer and fill")
    func jamGap() {
        for id in ContainerID.allCases where id.isDrawer {
            let spec = id.spec
            for n in 0...spec.hardCap {
                let sim = DrawerSim(id, count: n)
                #expect(sim.closedLimit == Float(min(6, max(0, n - spec.capacity))))
                #expect(sim.closedLimit == spec.closedLimit(count: n))
                #expect(sim.p == sim.closedLimit, "an overfull drawer rests ajar at its gap")
                #expect(sim.isJammed == (n >= spec.hardCap))
                #expect(sim.acceptsDrops == (n < spec.hardCap))
            }
        }
    }

    @Test("A flick shut slams at the closed stop; the detent holds it shut")
    func slam() {
        var sim = DrawerSim(.riserLeft, p: 10, count: 3)
        let events = flickShut(&sim)
        let slams = events.compactMap { if case let .slam(s) = $0 { s } else { nil } }
        #expect(slams.count == 1)
        #expect((slams.first ?? 0) > sim.params.slamSpeed)
        #expect(sim.p == 0 && sim.isAsleep)
        #expect(events.last == .settled(0))
    }

    @Test("A click toggle opens to the travel and closes softly (latch, no slam)")
    func toggle() {
        var sim = DrawerSim(.cabinetMiddle)
        sim.toggle()
        var events = runDrawer(&sim)
        #expect(sim.p == 14 && events.last == .settled(14))
        sim.toggle()
        events = runDrawer(&sim)
        #expect(sim.p == 0)
        #expect(!events.contains { if case .slam = $0 { true } else { false } })
        #expect(events.last == .settled(0))
    }

    @Test("Overfull: closing stops at the gap; a jammed drawer bounces back and never closes past it")
    func jam() {
        var over = DrawerSim(.riserLeft, p: 10, count: 11)
        _ = flickShut(&over)
        #expect(over.p == 3)

        var jammed = DrawerSim(.riserLeft, p: 10, count: 14)
        var minP = Float.infinity
        jammed.beginDrag()
        _ = jammed.step(Self.dt)
        jammed.drag(to: -10)
        _ = jammed.step(Self.dt)
        jammed.endDrag(releaseVelocity: -450)
        var events: [DrawerSim.Event] = []
        while jammed.needsFrames {
            events += jammed.step(Self.dt)
            minP = min(minP, jammed.p)
        }
        #expect(minP >= 6)
        #expect(events.contains { if case .jamThud = $0 { true } else { false } })
        // It bounces back out a little but stays shut enough to keep the contents hidden.
        #expect(jammed.p > 6 && jammed.p < Visibility.drawerOpen)
        // Holding it shut does not get past the gap either.
        jammed.beginDrag()
        jammed.drag(to: -20)
        for _ in 0..<60 { _ = jammed.step(Self.dt) }
        #expect(jammed.p >= 6)
    }

    @Test("Chair block: the cabinet limit is 3 px when the chair overlaps the front by more than 16 px")
    func chairBlock() {
        let cab = CoreLayout.cabinet, w = Float(CoreLayout.chair.w)
        #expect(DrawerSim.cabinetOpenLimit(travel: 12, chairX: 196) == 12)
        #expect(DrawerSim.cabinetOpenLimit(travel: 12, chairX: Float(cab.minX + 16) - w) == 12)
        #expect(DrawerSim.cabinetOpenLimit(travel: 12, chairX: Float(cab.minX + 17) - w) == 3)
        #expect(DrawerSim.cabinetOpenLimit(travel: 18, chairX: 400) == 3)
        #expect(DrawerSim.cabinetOpenLimit(travel: 18, chairX: .nan) == 18)

        var sim = DrawerSim(.cabinetTop)
        sim.setOpenLimit(DrawerSim.cabinetOpenLimit(travel: sim.travel, chairX: 400))
        sim.beginDrag()
        var events: [DrawerSim.Event] = []
        for f in 1...20 {
            sim.drag(to: Float(f))
            events += sim.step(Self.dt)
        }
        sim.endDrag()
        events += runDrawer(&sim)
        #expect(sim.p == 3)
        #expect(events.contains { if case .hitChair = $0 { true } else { false } })
        // The chair rolls away: the limit lifts and the drawer opens fully.
        sim.setOpenLimit(DrawerSim.cabinetOpenLimit(travel: sim.travel, chairX: 200))
        sim.open()
        _ = runDrawer(&sim)
        #expect(sim.p == 12)
    }

    @Test("Peek holds while scrolling; ending it closes the drawer")
    func peek() {
        var sim = DrawerSim(.riserRight)
        sim.peek(3)
        for _ in 0..<120 { _ = sim.step(Self.dt) }
        #expect(abs(sim.p - 3) < 0.5 && sim.needsFrames)
        sim.peek(9)
        for _ in 0..<60 { _ = sim.step(Self.dt) }
        #expect(abs(sim.p - sim.params.peekMax) < 0.5)
        sim.endPeek()
        let events = runDrawer(&sim)
        #expect(sim.p == 0 && events.last == .settled(0))
    }

    @Test("Chomp: opens, swallows once, closes; refused at the hard cap")
    func chomp() {
        var sim = DrawerSim(.cabinetTop, count: 2)
        let simChomp = sim.chomp()
        #expect(simChomp)
        var maxP: Float = 0
        var events: [DrawerSim.Event] = []
        while sim.needsFrames {
            events += sim.step(Self.dt)
            maxP = max(maxP, sim.p)
        }
        #expect(events.filter { $0 == .chompSwallow }.count == 1)
        #expect(maxP >= 5 && maxP <= 7)
        #expect(sim.p == 0)
        var full = DrawerSim(.cabinetTop, count: 14)
        let fullChomp = full.chomp()
        #expect(!fullChomp)
    }

    @Test("Knock: ajar non-jammed drawers within 3 px of their stop snap shut; others stay")
    func knock() {
        var ajar = DrawerSim(.riserLeft, p: 3, count: 2)
        let ajarKnock = ajar.knock()
        #expect(ajarKnock)
        _ = runDrawer(&ajar)
        #expect(ajar.p == 0)
        var open = DrawerSim(.riserLeft, p: 8, count: 2)
        let openKnock = open.knock()
        #expect(!openKnock)
        var overfull = DrawerSim(.riserLeft, p: 5, count: 10)
        let overfullKnock = overfull.knock()
        #expect(overfullKnock)
        _ = runDrawer(&overfull)
        #expect(overfull.p == 2)
        var jammed = DrawerSim(.riserLeft, p: 8, count: 14)
        let jammedKnock = jammed.knock()
        #expect(!jammedKnock)
        #expect(jammed.isAsleep)
    }

    @Test("More items push a closed drawer out to its new gap; settles report whole px")
    func setCount() {
        var sim = DrawerSim(.cabinetFile, count: 20)
        sim.setCount(24)
        let events = runDrawer(&sim)
        #expect(sim.p == 4 && events.last == .settled(4))
    }

    @Test("A slow release coasts and settles on a whole px once")
    func settlesOnce() {
        var sim = DrawerSim(.cabinetFile)
        sim.beginDrag()
        for f in 1...10 {
            sim.drag(to: Float(f) * 0.9)
            _ = sim.step(Self.dt)
        }
        sim.endDrag()
        let events = runDrawer(&sim)
        let settles = events.filter { if case .settled = $0 { true } else { false } }
        #expect(settles.count == 1)
        #expect(sim.p == sim.p.rounded() && sim.isAsleep)
        #expect(sim.step(Self.dt).isEmpty, "asleep: no events")
        _ = sim.forceRest()
        #expect(sim.forceRest().isEmpty)
    }

    @Test("Random inputs: p stays finite and within the stops; two runs are identical")
    func fuzz() {
        func run(_ seed: UInt64) -> [Float] {
            var rng = SplitMix64(seed: seed)
            var sim = DrawerSim(.cabinetMiddle, count: 10)
            var trace: [Float] = []
            for _ in 0..<3000 {
                switch rng.nextInt(below: 40) {
                case 0: sim.beginDrag()
                case 1: sim.drag(to: rng.nextFloat01() * 40 - 12)
                case 2: sim.endDrag(releaseVelocity: rng.nextFloat01() * 1200 - 600)
                case 3: sim.toggle()
                case 4: sim.setCount(rng.nextInt(in: 0...18))
                case 5: sim.setOpenLimit(rng.nextBool() ? 3 : 14)
                case 6: _ = sim.chomp()
                case 7: _ = sim.knock()
                case 8: sim.peek(rng.nextFloat01() * 6)
                case 9: sim.endPeek()
                default: break
                }
                _ = sim.step(Self.dt)
                #expect(sim.p.isFinite && sim.v.isFinite)
                #expect(sim.p >= 0 && sim.p <= sim.travel)
                trace.append(sim.p)
            }
            return trace
        }
        #expect(run(9) == run(9))
    }
}
