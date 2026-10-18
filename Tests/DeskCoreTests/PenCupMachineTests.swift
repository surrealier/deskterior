import Testing
@testable import DeskCore

@Suite("PenCupMachine")
struct PenCupMachineTests {
    static let dt: Float = 1.0 / 60

    static func settle(_ m: inout PenCupMachine) -> [PenCupMachine.Event] {
        var events: [PenCupMachine.Event] = []
        for _ in 0..<240 where m.needsFrames { events += m.step(dt) }
        return events
    }

    static func spilled(_ events: [PenCupMachine.Event]) -> Bool {
        events.contains { if case .spill = $0 { true } else { false } }
    }

    @Test("Tips only from a deliberate flick (> 400 px/s with ≥ 3 pens) or the menu")
    func tipsOnlyByGesture() {
        var slow = PenCupMachine()
        var events = slow.release(velocity: [380, 0], count: 6)
        events += Self.settle(&slow)
        #expect(slow.isUpright && !Self.spilled(events))
        #expect(events.contains(.wobble))

        var fewPens = PenCupMachine()
        events = fewPens.release(velocity: [900, 0], count: 2)
        events += Self.settle(&fewPens)
        #expect(fewPens.isUpright && !Self.spilled(events))

        var flick = PenCupMachine()
        events = flick.release(velocity: [-450, 30], count: 3)
        #expect(events == [.tipped(right: false)])
        events += Self.settle(&flick)
        #expect(flick.phase == .lying(right: false))
        #expect(events.contains(.spill(right: false)))
        #expect(events.last == .settled(PenCupState(state: "lyingLeft", pos: [367, 120])))

        var menu = PenCupMachine()
        events = menu.tipOut(right: true) + Self.settle(&menu)
        #expect(menu.phase == .lying(right: true) && events.contains(.spill(right: true)))
    }

    @Test("Knocks and bonks never tip it, whatever the sequence")
    func neverTipsByKnock() {
        var rng = SplitMix64(seed: 3)
        var m = PenCupMachine()
        for _ in 0..<2000 {
            var events: [PenCupMachine.Event]
            switch rng.nextInt(below: 3) {
            case 0: events = m.knock(strength: rng.nextFloat01() * 3)
            case 1: events = m.bonk()
            default: events = []
            }
            events += m.step(Self.dt)
            #expect(m.isUpright && !Self.spilled(events))
            #expect(abs(m.lean) <= 2)
        }
    }

    @Test("Tipping frames 0→2, then lying; standing up reverses them; the cup takes and gives pens only upright")
    func phases() {
        var m = PenCupMachine()
        #expect(m.canAccept(count: 5) && !m.canAccept(count: 6) && m.canPull(count: 1) && !m.canPull(count: 0))
        _ = m.tipOut(right: true)
        var poses: [PropArt.PenCupPose] = [m.pose]
        while m.needsFrames {
            _ = m.step(Self.dt)
            if poses.last != m.pose { poses.append(m.pose) }
        }
        #expect(poses == [.tipping(0), .tipping(1), .tipping(2), .lying(right: true)])
        #expect(!m.canAccept(count: 0) && !m.canPull(count: 3))
        let lyingBonk = m.bonk() == [.bonk]
        #expect(lyingBonk)
        _ = m.standUp()
        poses = [m.pose]
        var events: [PenCupMachine.Event] = []
        while m.needsFrames {
            events += m.step(Self.dt)
            if poses.last != m.pose { poses.append(m.pose) }
        }
        #expect(poses == [.tipping(2), .tipping(1), .tipping(0), .upright])
        #expect(events == [.righted, .settled(PenCupState(state: "upright", pos: [367, 120]))])
    }

    @Test("Persisted state round-trips; unknown names stand upright")
    func persisted() {
        for name in ["upright", "lyingLeft", "lyingRight"] {
            #expect(PenCupMachine(PenCupState(state: name, pos: [100, 40])).state == PenCupState(state: name, pos: [100, 40]))
        }
        #expect(PenCupMachine(PenCupState(state: "wobble", pos: [.nan, 3])).state == PenCupState())
        var m = PenCupMachine()
        m.carry(to: [200, 50], acceleration: [-4000, 0])
        #expect(m.lean == 2 && m.state.pos == [200, 50])
        m.sync(PenCupState(state: "lyingRight", pos: [10, 10]))
        #expect(m.phase == .lying(right: true))
    }

    @Test("Spill: deterministic landing spots, seeded spread, on the desk, the floor or the basket")
    func spill() {
        for (pos, right) in [(SIMD2<Float>(367, 120), true), (SIMD2<Float>(367, 120), false),
                             (SIMD2<Float>(250, 60), true), (SIMD2<Float>(480, 20), true), (SIMD2<Float>(30, 10), false)] {
            let a = PenCupMachine.spill(count: 6, from: pos, right: right, seed: 9)
            #expect(a == PenCupMachine.spill(count: 6, from: pos, right: right, seed: 9))
            #expect(a.count == 6 && a.map(\.index) == Array(0..<6))
            let w = PileWatchdog()
            for s in a {
                let speed = (s.velocity * s.velocity).sum().squareRoot()
                #expect(speed >= 150 - 0.01 && speed <= 300 + 0.01)
                #expect((s.velocity.x > 0) == right)
                switch s.landing {
                case let .desk(p):
                    #expect(w.inBounds(p), "\(p)")
                    #expect(s.edge == nil)
                case .floor, .basket:
                    #expect(s.edge != nil)
                }
            }
        }
        // Near the right edge everything goes over it.
        let edge = PenCupMachine.spill(count: 4, from: [480, 20], right: true, seed: 1)
        #expect(edge.allSatisfy { if case .floor = $0.landing { true } else { false } })
        #expect(PenCupMachine.spill(count: 6, from: [250, 60], right: true, seed: 1)
            != PenCupMachine.spill(count: 6, from: [250, 60], right: true, seed: 2))
        #expect(PenCupMachine.spill(count: 0, from: [250, 60], right: true, seed: 1).isEmpty)
    }

    @Test("Spilled pens start clear of the furniture, squeezed out in front of it")
    func spillStartsClear() {
        for (pos, right) in [(SIMD2<Float>(367, 120), true), (SIMD2<Float>(367, 120), false), (SIMD2<Float>(176, 120), true),
                             (SIMD2<Float>(250, 60), false)] {
            for s in PenCupMachine.spill(count: 6, from: pos, right: right, seed: 42) {
                let body = DeskPlaneRect.centred(at: s.start, size: DeskPlanePhysics.pileSize)
                #expect(!DeskPlanePhysics.footprints(stowed: []).values.contains { $0.intersects(body) }, "\(pos) \(right): \(s.start)")
            }
        }
    }

    @Test("The cup stays on the desk and out of the furniture, whatever the carry or the saved state says")
    func positionChecked() {
        var cup = PenCupMachine()
        cup.carry(to: [367, -60], acceleration: .zero)
        #expect(PenCupMachine.isValidPosition(cup.position) && cup.position == [367, 0])
        let offDesk = cup.release(velocity: .zero, count: 2) == [.settled(PenCupState(state: "upright", pos: [367, 0]))]
        #expect(offDesk)
        // Into the riser from in front: it stops short, sliding along x.
        var slide = PenCupMachine(PenCupState(state: "upright", pos: [300, 100]))
        slide.carry(to: [260, 125], acceleration: .zero)
        #expect(PenCupMachine.isValidPosition(slide.position) && slide.position == [260, 100])
        // Random carries never leave a valid spot.
        var rng = SplitMix64(seed: 4)
        var m = PenCupMachine()
        for _ in 0..<2000 {
            m.carry(to: [rng.nextFloat01() * 700 - 100, rng.nextFloat01() * 260 - 60], acceleration: .zero)
            #expect(PenCupMachine.isValidPosition(m.position), "\(m.position)")
        }
        #expect(PenCupMachine.isValidPosition(PenCupState().pos))
        // A saved spot off the desk or inside furniture is restored onto the desk / to the default.
        #expect(PenCupMachine(PenCupState(state: "upright", pos: [900, 300])).position == [493, 120])
        #expect(PenCupMachine(PenCupState(state: "upright", pos: [260, 120])).position == PenCupState().pos)
    }
}
