import Testing
@testable import DeskCore

@Suite("FloorLine")
struct FloorLineTests {
    @Test("Free spots keep the whole token in the core and clear of the basket, the cabinet and the desk's legs")
    func freeSpots() {
        #expect(FloorLine.centres == 8...504)
        #expect(FloorLine.isFree(40) && !FloorLine.isFree(41) && !FloorLine.isFree(87) && FloorLine.isFree(88))
        #expect(FloorLine.isFree(384) && !FloorLine.isFree(385) && !FloorLine.isFree(479) && !FloorLine.isFree(480))
        // The legs: 18–26 and 486–494; the 14 px between the cabinet and the right leg take no token.
        #expect(FloorLine.isFree(10) && !FloorLine.isFree(11) && !FloorLine.isFree(33) && FloorLine.isFree(34))
        #expect(!FloorLine.isFree(478) && !FloorLine.isFree(501) && FloorLine.isFree(502))
        #expect(FloorLine.freeSpot(near: 200.4) == 200)
        #expect(FloorLine.freeSpot(near: 60) == 40 && FloorLine.freeSpot(near: 70) == 88 && FloorLine.freeSpot(near: 64) == 40)
        #expect(FloorLine.freeSpot(near: 430) == 384 && FloorLine.freeSpot(near: 450) == 502)
        #expect(FloorLine.freeSpot(near: -50) == 8 && FloorLine.freeSpot(near: 999) == 504)
        #expect(FloorLine.freeSpot(near: .nan) == 8)
        // The chair's base, for landings: its left edge and width.
        #expect(FloorLine.chair(at: 196) == 196..<268 && FloorLine.chair(at: .nan) == CoreLayout.chair.minX..<CoreLayout.chair.maxX)
        for x in stride(from: Float(-20), through: 540, by: 0.5) {
            #expect(FloorLine.isFree(FloorLine.freeSpot(near: x)), "\(x)")
        }
    }

    @Test("Rows step over furniture and stop at the core's edge")
    func rows() {
        #expect(FloorLine.row(from: 350, direction: 1, pitch: 18, count: 9) == [350, 368, 502])
        #expect(FloorLine.row(from: 120, direction: -1, pitch: 30, count: 9) == [120, 90, 40, 10])
        #expect(FloorLine.row(from: 300, direction: 1, pitch: 10, count: 3) == [300, 310, 320])
        #expect(FloorLine.row(from: 600, direction: 1, pitch: 10, count: 3).isEmpty)
    }

    // MARK: tidy (0.3.0): with the cabinet put away its span is free floor, for landings, moves and spills.

    @Test("A put-away cabinet's span drops out of the furniture, whichever way the basket stands")
    func furnitureWithCabinetAway() {
        let cabinet = CoreLayout.cabinet.minX..<CoreLayout.cabinet.maxX
        for basket in [BasketState(), BasketState(state: WastebasketMachine.tippedLeftName),
                       BasketState(state: WastebasketMachine.tippedRightName)] {
            let out = FloorLine.furniture(basket: basket)
            let away = FloorLine.furniture(basket: basket, stowed: [.cabinet])
            #expect(out.contains(cabinet) && !away.contains(cabinet) && away.count == out.count - 1, "\(basket.state)")
            #expect(FloorLine.furniture(basket: basket, stowed: Set(StowID.allCases).subtracting([.cabinet])) == out)
        }
    }

    @Test("Floor spots and floor moves use the cabinet's span while it is away")
    func spotsWithCabinetAway() {
        let cabinet = CoreLayout.cabinet.minX..<CoreLayout.cabinet.maxX, mid = CoreLayout.cabinet.midX
        #expect(!cabinet.contains(Reducer.floorSpots(near: mid, count: 1)[0]))
        #expect(Reducer.floorSpots(near: mid, count: 1, stowed: [.cabinet]) == [mid])
        var s = ModelFixture.mirrored(["a", "b"])
        let env = ReduceEnv(now: ModelFixture.t0)
        _ = reduce(&s, .putAway(.cabinet), env)
        _ = reduce(&s, .move([ModelFixture.key(1), ModelFixture.key(2)], to: .floor(x: mid)), env)
        #expect(s.tokens.location(of: ModelFixture.key(1)) == .floor(x: mid))
        #expect(s.tokens.location(of: ModelFixture.key(2)) == .floor(x: mid + Placement.floorSpacing))
    }
}
