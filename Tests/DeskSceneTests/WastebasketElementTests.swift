import DeskCore
import Foundation
import Testing
@testable import DeskScene

/// A desk with tokens 1…`balls` in the wastebasket, the rest on the monitor.
private func basketDesk(balls: Int) -> DeskState {
    var s = SceneFixture.state(SceneFixture.names + (0..<20).map { "more \($0).txt" })
    for i in 0..<balls { s.tokens.move(SceneFixture.key(UInt64(i + 1)), to: .container(.wastebasket, order: i)) }
    return s
}

@Suite("Wastebasket element")
struct WastebasketElementTests {
    typealias F = SceneFixture

    @Test("A gentle drop at the mouth hops in; the heap shows above the rim from the 11th ball; the tooltip reassures")
    func gentleDropAndHeap() throws {
        let stage = try PhysicsStage(basketDesk(balls: 10), physics: false)
        let basket = stage.hub.basket
        let lowBounds = basket.bounds
        let mouth = stage.centre(try #require(stage.scene.physicsAnchor("wastebasket.mouth")))
        stage.drag(try #require(stage.tokenPoint(F.key(20))), mouth - SIMD2(0, 8), steps: 30, pause: 6)
        #expect(stage.hub.tosses.flights.count == 1, "hopping in")
        stage.settle()
        #expect(stage.location(F.key(20)) == .container(.wastebasket, order: 10))
        #expect(stage.state.wastebasket.swishes == 0, "a drop is not a swish")
        #expect(basket.bounds == lowBounds, "one sprite covers the risen heap")
        let heap = InteriorRaster.wastebasket(InteriorRaster.items(.wastebasket, in: stage.state))
        let rimRow = InteriorRaster.heapRise - 1
        #expect((0..<heap.image.width).contains { heap.image.pixel($0, rimRow).a != 0 }, "a ball above the rim")
        let hit = try #require(stage.scene.hitTest(ArtPoint(Int(mouth.x), Int(mouth.y))))
        #expect(basket.tooltip(hit)?.detail == "11 items — hidden, not deleted.")
    }

    @Test("Full at 24: a further drop bonks with \"That's full\" and the heap jiggles; nothing comes out on its own")
    func capBonks() throws {
        let stage = try PhysicsStage(basketDesk(balls: 24), physics: false)
        let mouth = stage.centre(try #require(stage.scene.physicsAnchor("wastebasket.mouth")))
        stage.drag(try #require(stage.tokenPoint(F.key(30))), mouth, steps: 30, pause: 6)
        stage.frames(1)
        #expect(stage.scene.bonkCount == 1 && stage.scene.toastShown == .containerFull)
        #expect(stage.hub.basket.machine.jiggle > 0)
        stage.settle()
        #expect(stage.state.tokens.count(in: .wastebasket) == 24 && stage.location(F.key(30))?.isScreen == true)
    }

    @Test("A slow sideways rim drag tips nothing; a sustained fast one tips it (Errata 13) and the balls roll out")
    func rimDragTips() throws {
        let stage = try PhysicsStage(basketDesk(balls: 5), physics: false)
        let mouth = stage.centre(try #require(stage.scene.physicsAnchor("wastebasket.mouth")))
        // 4 px a frame is 240 px/s: under the tip speed. Kept level, it does not dig either.
        stage.drag(mouth, mouth + SIMD2(4, 0), steps: 1)
        stage.drag(mouth, mouth + SIMD2(7, 0), steps: 2)
        stage.settle()
        #expect(stage.hub.basket.machine.isUpright && stage.state.tokens.count(in: .wastebasket) == 5)
        stage.drag(mouth, mouth + SIMD2(40, 0), steps: 6)
        #expect(!stage.hub.basket.machine.isUpright)
        stage.settle()
        #expect(stage.state.wastebasket.state == WastebasketMachine.tippedRightName)
        // The balls keep clear of the chair where it stands (the model's, drawn by the chair element).
        let chair = FloorLine.chair(at: stage.scene.chairX ?? Float(CoreLayout.chair.x))
        let spots = WastebasketMachine.spillSpots(count: 5, right: true, avoiding: [chair])
        for k in UInt64(1)...5 {
            #expect(stage.location(F.key(k)) == .floor(x: spots[Int(k) - 1]), "ball \(k)")
        }
        // A click stands it back up, empty.
        stage.click(stage.centre(stage.hub.basket.bounds))
        stage.settle()
        #expect(stage.state.wastebasket.state == WastebasketMachine.uprightName && stage.hub.basket.machine.isUpright)
    }

    @Test("A drag up out of the mouth digs: the top ball comes out as its token")
    func dig() throws {
        let stage = try PhysicsStage(basketDesk(balls: 3), physics: false)
        let mouth = stage.centre(try #require(stage.scene.physicsAnchor("wastebasket.mouth")))
        stage.drag(mouth, mouth - SIMD2(0, 12), steps: 6, hold: true)
        #expect(stage.scene.isDragging && stage.scene.screen?.carried == [F.key(3)], "the top ball, in hand")
        let start = mouth - SIMD2(0, 12), cell = stage.centre(try #require(stage.scene.screen).cellRect(8, 4))
        for k in 1...20 {
            stage.event(.drag, start + (cell - start) * Float(k) / 20)
            stage.frames(1)
        }
        stage.frames(6)
        stage.event(.up, cell, count: 1)
        stage.settle()
        #expect(stage.location(F.key(3))?.isScreen == true)
        #expect(stage.state.tokens.members(of: .wastebasket) == [F.key(1), F.key(2)])
    }

    @Test("A toss in front of the mouth is a swish, counted and saved; Empty Wastebasket… waits for M11")
    func swishAndMenu() throws {
        let stage = try PhysicsStage(basketDesk(balls: 0), physics: false)
        let from = try #require(stage.tokenPoint(F.key(1)))
        stage.drag(from, stage.point(core: 64, 250), steps: 30, pause: 6)
        stage.settle()
        #expect(stage.location(F.key(1)) == .container(.wastebasket, order: 0))
        #expect(stage.state.wastebasket.swishes == 1)
        let menu = stage.scene.contextMenu(at: stage.hub.basket.bounds.center)
        #expect(menu.item("emptyWastebasket")?.isEnabled == false && menu.item("tipOver")?.isEnabled == true)
        #expect(menu.item("emptyWastebasket")?.title == "Empty Wastebasket… (1)")
    }
}
