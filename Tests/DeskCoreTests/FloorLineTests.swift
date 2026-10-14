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
}
