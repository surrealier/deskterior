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

    @Test("Overfull: closing stops at the gap; a jammed drawer boings off it and rests exactly on it")
    func jam() {
        var over = DrawerSim(.riserLeft, p: 10, count: 11)
        _ = flickShut(&over)
        #expect(over.p == 3)

        for id in ContainerID.allCases where id.isDrawer {
            let gap = Float(min(6, id.spec.hardCap - id.spec.capacity))
            // Flicked shut: one boing out and back, quickly, never far enough to show the contents.
            var jammed = DrawerSim(id, p: id.spec.travel!, count: id.spec.hardCap)
            jammed.beginDrag()
            _ = jammed.step(Self.dt)
            jammed.drag(to: -jammed.travel)
            _ = jammed.step(Self.dt)
            jammed.endDrag(releaseVelocity: -450)
            var events: [DrawerSim.Event] = []
            var trace: [Float] = []
            for _ in 0..<120 where jammed.needsFrames {
                events += jammed.step(Self.dt)
                trace.append(jammed.p)
            }
            #expect(trace.min()! >= gap)
            #expect(events.filter { if case .jamThud = $0 { true } else { false } }.count == 1, "\(id)")
            let thud = trace.firstIndex(of: gap)!
            let rebound = trace[thud...].max()! - gap
            #expect(rebound >= 0.5 && rebound < Visibility.drawerOpen - 0.5 - gap, "\(id): a visible boing, contents hidden")
            #expect(trace.count - thud < 24, "\(id): over within 0.4 s")
            #expect(jammed.p == gap && events.last == .settled(gap) && !jammed.isRevealed)
            // Closed by a click it rests on the gap too.
            var clicked = DrawerSim(id, p: id.spec.travel!, count: id.spec.hardCap)
            clicked.toggle()
            _ = runDrawer(&clicked)
            #expect(clicked.p == gap)
        }
        // Holding it shut does not get past the gap either.
        var held = DrawerSim(.riserLeft, p: 10, count: 14)
        held.beginDrag()
        held.drag(to: -20)
        for _ in 0..<60 { _ = held.step(Self.dt) }
        #expect(held.p >= 6)
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

    @Test("Click and spring-loading thunk into the chair (so it rolls aside); the next click retries and opens")
    func clickIntoChair() {
        for id in [ContainerID.cabinetTop, .cabinetMiddle, .cabinetFile] {
            var sim = DrawerSim(id)
            sim.setOpenLimit(DrawerSim.cabinetOpenLimit(travel: sim.travel, chairX: 400))
            sim.toggle()
            var events = runDrawer(&sim)
            let thunks = events.filter { if case .hitChair = $0 { true } else { false } }
            #expect(thunks.count == 1, "\(id): \(events)")
            #expect(sim.p == 3 && events.last == .settled(3))
            // The thunk pushed the chair clear; the second click opens (not closes) the drawer.
            sim.setOpenLimit(DrawerSim.cabinetOpenLimit(travel: sim.travel, chairX: 300))
            sim.toggle()
            events = runDrawer(&sim)
            #expect(sim.p == sim.travel, "\(id)")
            #expect(!events.contains { if case .hitChair = $0 { true } else { false } })
            // A chair still there: the retry thunks again.
            var blocked = DrawerSim(id, p: 3)
            blocked.setOpenLimit(3)
            blocked.open()
            events = runDrawer(&blocked)
            #expect(events.contains { if case .hitChair = $0 { true } else { false } } && blocked.p == 3)
        }
        // Spring-loading's open() on the file drawer thunks as well.
        var file = DrawerSim(.cabinetFile)
        file.setOpenLimit(3)
        file.open()
        let events = runDrawer(&file)
        #expect(events.contains { if case .hitChair = $0 { true } else { false } } && file.p == 3)
    }

    @Test("The cabinet drawers are interlocked; the riser's are not")
    func interlock() {
        #expect(DrawerSim.interlocked(.cabinetMiddle) == [.cabinetTop, .cabinetFile])
        #expect(DrawerSim.interlocked(.cabinetTop) == [.cabinetMiddle, .cabinetFile])
        #expect(DrawerSim.interlocked(.riserLeft).isEmpty && DrawerSim.interlocked(.wastebasket).isEmpty)
    }

    @Test("Peek holds while scrolling; ending it, or no scroll for a moment (a mouse wheel), closes the drawer")
    func peek() {
        var sim = DrawerSim(.riserRight)
        for _ in 0..<120 {
            sim.peek(3)
            _ = sim.step(Self.dt)
        }
        #expect(abs(sim.p - 3) < 0.5 && sim.needsFrames && !sim.isRevealed)
        for _ in 0..<60 {
            sim.peek(9)
            _ = sim.step(Self.dt)
        }
        #expect(abs(sim.p - sim.params.peekMax) < 0.5)
        sim.endPeek()
        var events = runDrawer(&sim)
        #expect(sim.p == 0 && events.last == .settled(0))

        // A wheel: scroll events, then nothing. The peek lets go by itself and the drawer sleeps.
        var wheel = DrawerSim(.riserLeft)
        var frames = 0
        events = []
        for f in 0..<600 where wheel.needsFrames || f == 0 {
            if f < 10 { wheel.peek(3) }
            events += wheel.step(Self.dt)
            frames += 1
        }
        #expect(!wheel.needsFrames && wheel.p == 0 && events.last == .settled(0))
        #expect(frames < 60, "closes within a second of the last scroll")
    }

    @Test("A chomp swallows exactly once even when a grab, click, knock, new chomp or hard sleep interrupts it")
    func chompInterrupted() {
        func chomped(_ interrupt: (inout DrawerSim) -> [DrawerSim.Event]) -> (swallows: Int, sim: DrawerSim) {
            var sim = DrawerSim(.riserLeft, count: 2)
            _ = sim.chomp()
            var events = sim.step(Self.dt)
            events += interrupt(&sim)
            if sim.isDragging { sim.endDrag() }
            events += runDrawer(&sim)
            return (events.filter { $0 == .chompSwallow }.count, sim)
        }
        let grabbed = chomped { sim in
            sim.beginDrag()
            return sim.step(Self.dt)
        }
        #expect(grabbed.swallows == 1)
        let toggled = chomped { sim in
            sim.toggle()
            return []
        }
        #expect(toggled.swallows == 1)
        var knocked = true
        let knock = chomped { sim in
            knocked = sim.knock()
            return []
        }
        #expect(!knocked && knock.swallows == 1, "a knock leaves a chomping drawer alone")
        let twice = chomped { sim in
            _ = sim.chomp()
            return []
        }
        #expect(twice.swallows == 2, "two drops, two swallows")
        let slept = chomped { sim in sim.forceRest() }
        #expect(slept.swallows == 1)
    }

    @Test("Contents show as icons from the reveal until the drawer shuts: no swap for paper while it slides")
    func reveal() {
        // Slammed shut from open: revealed all the way in.
        var slam = DrawerSim(.riserLeft, p: 10, count: 3)
        #expect(slam.isRevealed)
        slam.beginDrag()
        _ = slam.step(Self.dt)
        slam.drag(to: -10)
        _ = slam.step(Self.dt)
        slam.endDrag(releaseVelocity: -450)
        var seen: [(Float, Bool)] = []
        for _ in 0..<120 where slam.needsFrames {
            _ = slam.step(Self.dt)
            seen.append((slam.p, slam.isRevealed))
        }
        let shut = seen.firstIndex { $0.0 <= 0 }!
        #expect(seen[..<shut].allSatisfy(\.1) && !seen[shut...].contains { $0.1 }, "\(seen)")
        #expect(!slam.isRevealed && slam.p == 0)
        // A click open shows icons from its first frame.
        var click = DrawerSim(.cabinetMiddle)
        click.toggle()
        _ = click.step(Self.dt)
        #expect(click.isRevealed && click.p < Visibility.drawerOpen)
        _ = runDrawer(&click)
        #expect(click.isRevealed)
        // A drag that stops short of 8 px only peeks: paper once it rests.
        var drag = DrawerSim(.cabinetMiddle)
        drag.beginDrag()
        for f in 1...6 {
            drag.drag(to: Float(f))
            _ = drag.step(Self.dt)
        }
        drag.endDrag(releaseVelocity: 0)
        _ = runDrawer(&drag)
        #expect(!drag.isRevealed && drag.p < Visibility.drawerOpen)
        // A chomp never reveals.
        var chomp = DrawerSim(.riserLeft, count: 2)
        _ = chomp.chomp()
        for _ in 0..<60 {
            _ = chomp.step(Self.dt)
            #expect(!chomp.isRevealed)
        }
    }

    @Test("Non-finite or huge steps never corrupt the drawer, the jostle or the chair")
    func badSteps() {
        for dt: Float in [.infinity, .nan, -1, 0, 0.5, 1e6] {
            var sim = DrawerSim(.riserLeft, p: 5)
            sim.toggle()
            _ = sim.step(dt)
            #expect(sim.p.isFinite && sim.v.isFinite && sim.acceleration.isFinite, "dt \(dt)")
            #expect(sim.p >= 0 && sim.p <= sim.travel && sim.pixel >= 0)
            var j = ContentJostle(homes: [7, 8], bounds: 3...8)
            j.step(drawerAcceleration: 1e5, dt)
            #expect(j.positions.allSatisfy { $0.isFinite && (3...8).contains($0) } && j.velocities.allSatisfy(\.isFinite))
            var c = RollerSim(x: 200)
            c.push(500)
            _ = c.step(dt)
            #expect(c.x.isFinite && c.v.isFinite && c.spin.isFinite && c.params.travel.contains(c.x))
        }
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
