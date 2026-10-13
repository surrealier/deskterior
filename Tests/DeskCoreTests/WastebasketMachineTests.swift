import Testing
@testable import DeskCore

@Suite("WastebasketMachine")
struct WastebasketMachineTests {
    static let dt: Float = 1.0 / 60

    static func settle(_ m: inout WastebasketMachine) -> [WastebasketMachine.Event] {
        var events: [WastebasketMachine.Event] = []
        for _ in 0..<240 where m.needsFrames { events += m.step(dt) }
        return events
    }

    @Test("Hard cap 24: the 25th bonks; 24 heap slots, above the rim from 11")
    func cap() {
        let m = WastebasketMachine()
        #expect(m.canAccept(count: 23) && !m.canAccept(count: 24))
        #expect(m.drop(count: 10).isEmpty && m.drop(count: 24) == [.bonk])
        #expect(WastebasketMachine.heapSlot(0) != nil && WastebasketMachine.heapSlot(23) != nil)
        #expect(WastebasketMachine.heapSlot(24) == nil)
        #expect(!WastebasketMachine.isHeapedAboveRim(10) && WastebasketMachine.isHeapedAboveRim(11))
    }

    @Test("Nothing leaves on its own: random knocks, drops and time never spill or tip it")
    func noAutoSpill() {
        var rng = SplitMix64(seed: 12)
        var m = WastebasketMachine(BasketState(state: "upright", swishes: 3))
        for _ in 0..<3000 {
            var events: [WastebasketMachine.Event] = []
            switch rng.nextInt(below: 4) {
            case 0: events = m.knock()
            case 1: events = m.drop(count: rng.nextInt(in: 0...30))
            case 2: events = m.rimDrag(delta: SIMD2(rng.nextFloat01() * 9.8 - 4.9, 0), dt: Self.dt)
            default: break
            }
            events += m.step(Self.dt)
            #expect(m.isUpright)
            #expect(!events.contains { if case .spill = $0 { true } else { false } })
        }
        #expect(m.state == BasketState(state: "upright", swishes: 3))
    }

    /// Drags the rim by `delta` per frame for `frames` frames, collecting events.
    static func drag(_ m: inout WastebasketMachine, _ delta: SIMD2<Float>, frames: Int) -> [WastebasketMachine.Event] {
        (0..<frames).flatMap { _ in m.rimDrag(delta: delta, dt: dt) }
    }

    @Test("A sustained sideways rim drag tips it; it spills once on landing; a click stands it up")
    func tip() {
        var m = WastebasketMachine()
        let slow = Self.drag(&m, [4.9, 0], frames: 10).isEmpty
        #expect(slow)
        m.endRimDrag()
        let fast = Self.drag(&m, [-6, 0.5], frames: 3) == [.tipped(right: false)]
        #expect(fast)
        #expect(m.state.state == "tippedLeft" && !m.canAccept(count: 0) && !m.canDig(count: 3))
        var events = Self.settle(&m)
        #expect(events == [.spill(right: false), .settled(BasketState(state: "tippedLeft", swishes: 0))])
        let tippedIgnores = m.isTipped && Self.drag(&m, [20, 0], frames: 5).isEmpty
        #expect(tippedIgnores)
        _ = m.standUp()
        events = Self.settle(&m)
        #expect(events == [.righted, .settled(BasketState())] && m.isUpright)
        let menu = m.tipOut(right: true) == [.tipped(right: true)]
        #expect(menu)
    }

    @Test("A quick dig out of the mouth never tips it: one fast sample, up-and-down drags, wobbles and short flicks")
    func digNeverTips() {
        var m = WastebasketMachine()
        // A single fast sideways sample (the dig's first jerk), then the dig goes up.
        var events = m.rimDrag(delta: [12, -2], dt: Self.dt)
        events += Self.drag(&m, [3, -9], frames: 8)
        #expect(events.isEmpty && m.isUpright)
        m.endRimDrag()
        // Fast but mostly vertical.
        events = Self.drag(&m, [7, -24], frames: 10)
        #expect(events.isEmpty && m.isUpright)
        m.endRimDrag()
        // Fast sideways jitter that keeps changing direction.
        events = (0..<12).flatMap { i in m.rimDrag(delta: [i % 2 == 0 ? 8 : -8, 0], dt: Self.dt) }
        #expect(events.isEmpty && m.isUpright)
        m.endRimDrag()
        // Two fast samples are not enough; a slower one in between resets the count.
        events = Self.drag(&m, [8, 0], frames: 2) + Self.drag(&m, [2, 0], frames: 1) + Self.drag(&m, [8, 0], frames: 2)
        #expect(events.isEmpty && m.isUpright)
        m.endRimDrag()
        // Three fast samples that cover no more than 6 px.
        events = (0..<3).flatMap { _ in m.rimDrag(delta: [2, 0], dt: 1.0 / 240) }
        #expect(events.isEmpty && m.isUpright)
        m.endRimDrag()
        let tipped = Self.drag(&m, [6, -1], frames: 3) == [.tipped(right: true)]
        #expect(tipped)
    }

    @Test("Swishes are counted; a rim-in is not; a full basket bonks the ball out")
    func swishes() {
        var m = WastebasketMachine()
        let (p, v) = Ballistics.release(at: SIMD2(64, 250), velocity: .zero)
        let swish = Ballistics.toss(from: p, velocity: v)
        let swished = m.recordToss(swish, count: 3) == [.swish, .settled(BasketState(state: "upright", swishes: 1))]
        #expect(swished)
        #expect(m.swishes == 1)
        let overfull = m.recordToss(swish, count: 24) == [.bonk] && m.swishes == 1
        #expect(overfull)
        let miss = Ballistics.pushOff(at: SIMD2(300, 0), velocity: SIMD2(0, -50))
        let missed = m.recordToss(miss, count: 3).isEmpty
        #expect(missed)
        #expect(WastebasketMachine(BasketState(state: "tippedRight", swishes: 7)).state
            == BasketState(state: "tippedRight", swishes: 7))
        #expect(WastebasketMachine(BasketState(state: "??", swishes: -2)).state == BasketState())
    }

    @Test("Gentle drops within 12 px of the mouth; spill spots are free floor centres, top ball nearest the mouth")
    func dropsAndSpots() {
        let m = WastebasketMachine()
        let mouth = CoreLayout.wastebasketMouth
        #expect(m.isGentleDrop(at: mouth.center))
        #expect(m.isGentleDrop(at: ArtPoint(mouth.minX - 12, mouth.minY - 12)))
        #expect(!m.isGentleDrop(at: ArtPoint(mouth.minX - 13, mouth.midY)))
        let cabinet = CoreLayout.cabinet.minX..<CoreLayout.cabinet.maxX
        for right in [true, false] {
            let lying = WastebasketMachine.tippedRect(right: right)
            #expect(lying.size == ArtSize(CoreLayout.wastebasket.h, CoreLayout.wastebasket.w))
            #expect(lying.maxY == CoreLayout.floorY && (right ? lying.minX == mouth.maxX : lying.maxX == mouth.minX))
            for n in [1, 5, 12, 17, 24] {
                let spots = WastebasketMachine.spillSpots(count: n, right: right)
                #expect(spots.count == n)
                #expect(spots.allSatisfy { FloorLine.isFree($0, avoiding: [lying.minX..<lying.maxX, cabinet]) },
                        "\(right) \(n): \(spots)")
                #expect(spots == WastebasketMachine.spillSpots(count: n, right: right))
                let mouthX = right ? lying.maxX : lying.minX
                let dist = spots.map { abs($0 - mouthX) }
                #expect(dist.last == dist.min(), "the top ball lands nearest the mouth")
            }
        }
        #expect(WastebasketMachine.spillSpots(count: 0, right: true).isEmpty)
    }
}
