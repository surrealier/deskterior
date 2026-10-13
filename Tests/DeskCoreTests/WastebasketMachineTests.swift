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
            case 2: events = m.rimDrag(velocityX: rng.nextFloat01() * 600 - 300)
            default: break
            }
            events += m.step(Self.dt)
            #expect(m.isUpright)
            #expect(!events.contains { if case .spill = $0 { true } else { false } })
        }
        #expect(m.state == BasketState(state: "upright", swishes: 3))
    }

    @Test("A fast rim drag tips it; it spills once on landing; a click stands it up")
    func tip() {
        var m = WastebasketMachine()
        let slow = m.rimDrag(velocityX: 299).isEmpty
        #expect(slow)
        let fast = m.rimDrag(velocityX: -301) == [.tipped(right: false)]
        #expect(fast)
        #expect(m.state.state == "tippedLeft" && !m.canAccept(count: 0) && !m.canDig(count: 3))
        var events = Self.settle(&m)
        #expect(events == [.spill(right: false), .settled(BasketState(state: "tippedLeft", swishes: 0))])
        let tippedIgnores = m.isTipped && m.rimDrag(velocityX: 900).isEmpty
        #expect(tippedIgnores)
        _ = m.standUp()
        events = Self.settle(&m)
        #expect(events == [.righted, .settled(BasketState())] && m.isUpright)
        let menu = m.tipOut(right: true) == [.tipped(right: true)]
        #expect(menu)
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

    @Test("Gentle drops within 12 px of the mouth; spill spots fit on the floor, top ball nearest")
    func dropsAndSpots() {
        let m = WastebasketMachine()
        let mouth = CoreLayout.wastebasketMouth
        #expect(m.isGentleDrop(at: mouth.center))
        #expect(m.isGentleDrop(at: ArtPoint(mouth.minX - 12, mouth.minY - 12)))
        #expect(!m.isGentleDrop(at: ArtPoint(mouth.minX - 13, mouth.midY)))
        for right in [true, false] {
            for n in [1, 5, 12, 24] {
                let spots = WastebasketMachine.spillSpots(count: n, right: right)
                #expect(spots.count == n)
                #expect(spots.allSatisfy { $0 >= 0 && $0 <= CoreLayout.size.w - 16 })
                #expect(spots == WastebasketMachine.spillSpots(count: n, right: right))
                let dist = spots.map { abs($0 + 8 - mouth.midX) }
                #expect(dist.last == dist.min(), "the top ball lands nearest the basket")
            }
        }
        #expect(WastebasketMachine.spillSpots(count: 0, right: true).isEmpty)
    }
}
