import DeskCore
import Foundation
import Metal
import Testing
@testable import DeskScene

/// Carries let go over the desk, flung, or dropped below it (DESIGN §2.1 DropResolver, fling; Errata 13).
@Suite("Fling: drops on the desk, flings and falls")
struct FlingTests {
    typealias F = SceneFixture

    @Test("A gentle drop on the bare desk makes a pile where the stack's base was; journaled as a move")
    func gentleDropMakesPile() throws {
        let stage = try PhysicsStage(F.state(), physics: false)
        let from = try #require(stage.tokenPoint(F.key(1)))
        let to = stage.point(core: 250, 214)
        stage.drag(from, to, steps: 12, pause: 6)
        stage.frames(10)
        let loc = try #require(stage.location(F.key(1)))
        let pile = try #require(loc.pile, "landed on the desk: \(loc)")
        let pos = try #require(stage.state.piles[pile])
        // The icon was held by its centre, so its base was 8 px below the pointer (core y 222): it lands on the desk
        // point under it, d = 2·(232 − 222) = 20.
        #expect(abs(pos.x - 250) <= 1 && abs(pos.y - 20) <= 1, "\(pos)")
        #expect(stage.journal.undoLabel == "Move")
        #expect(stage.scene.deskTokenRect(F.key(1)) != nil, "drawn in its pile")
        #expect(!stage.scene.isDragging && stage.scene.screen?.carried.isEmpty == true)
    }

    @Test("A second drop within 10 px joins the pile; a drop elsewhere starts another")
    func joinsNearbyPile() throws {
        let stage = try PhysicsStage(F.state(), physics: false)
        for (k, x) in [(UInt64(1), 250), (2, 254), (3, 330)] {
            let from = try #require(stage.tokenPoint(F.key(k)))
            stage.drag(from, stage.point(core: x, 214), steps: 12, pause: 6)
            stage.frames(10)
        }
        let p1 = try #require(stage.location(F.key(1))?.pile)
        #expect(stage.location(F.key(2)) == .desk(pile: p1, order: 1))
        let p3 = try #require(stage.location(F.key(3))?.pile)
        #expect(p3 != p1 && stage.state.tokens.piles.count == 2)
    }

    @Test("A release over the desk lands on the desk however fast; one below its front edge flies to the floor")
    func fastReleaseLandsOnDesk() throws {
        let stage = try PhysicsStage(F.state(), physics: false)
        let from = try #require(stage.tokenPoint(F.key(1)))
        stage.drag(from, stage.point(core: 300, 200), steps: 4)
        stage.settle()
        #expect(stage.location(F.key(1))?.pile != nil, "\(String(describing: stage.location(F.key(1))))")
        let other = try #require(stage.tokenPoint(F.key(2)))
        stage.drag(other, stage.point(core: 300, 262), steps: 4)
        #expect(stage.scene.isDragging == false && stage.hub.tosses.flights.count == 1, "in the air")
        #expect(stage.scene.screen?.carried == [F.key(2)], "still off the screen while it flies")
        stage.settle()
        guard case let .floor(x)? = stage.location(F.key(2)) else {
            Issue.record("expected the floor, got \(String(describing: stage.location(F.key(2))))")
            return
        }
        #expect(FloorLine.isFree(x))
        #expect(stage.journal.undoLabel == "Move" && stage.scene.screen?.carried.isEmpty == true)
    }

    @Test("A slow release over the bare wall springs back; affordances keep their drops")
    func slowReleaseOnWallSpringsBack() throws {
        let stage = try PhysicsStage(F.state(), physics: false)
        let from = try #require(stage.tokenPoint(F.key(1)))
        stage.drag(from, stage.point(core: 460, 100), steps: 12, pause: 6)
        stage.settle()
        #expect(stage.location(F.key(1))?.isScreen == true && stage.actions.isEmpty)
        // A fast drop onto another screen cell is still a screen move.
        let cell = try #require(stage.scene.screen).cellRect(6, 4)
        stage.drag(from, stage.centre(cell), steps: 3)
        stage.settle()
        #expect(stage.location(F.key(1)) == .screen(page: 0, col: 6, row: 4))
    }

    @Test("A flight shows a shadow on the floor below it and lands at once on a hard sleep")
    func flightShadowAndHardSleep() throws {
        let stage = try PhysicsStage(F.state(), physics: false)
        let from = try #require(stage.tokenPoint(F.key(1)))
        stage.drag(from, stage.point(core: 200, 262), steps: 12, pause: 6)
        let flight = try #require(stage.hub.tosses.flights.first)
        stage.frames(3)
        #expect(!flight.node.isHidden && !flight.shadow.isHidden, "a shadow below the token")
        let shadow = stage.scene.space.artRect(flight.shadow.frame)
        #expect(shadow.maxY >= stage.layout.floorY && shadow.minY <= stage.layout.floorY + 1, "\(shadow)")
        stage.scene.forceRest()
        #expect(stage.hub.tosses.flights.isEmpty)
        if case .floor? = stage.location(F.key(1)) {} else { Issue.record("landed: \(String(describing: stage.location(F.key(1))))") }
        #expect(!stage.scene.isDragging && stage.scene.screen?.carried.isEmpty == true)
    }
}

@Suite("Fling with physics", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct FlingPhysicsTests {
    typealias F = SceneFixture

    @Test("A toss dropped above the basket ends inside (DESIGN §14 M7)")
    func dropAboveBasketEndsInside() throws {
        let stage = try PhysicsStage(F.state(), physics: true)
        let from = try #require(stage.tokenPoint(F.key(1)))
        // Let go just above the mouth, below the desk's front edge: it falls in.
        stage.drag(from, stage.point(core: 64, 250), steps: 20, pause: 6)
        stage.settle()
        #expect(stage.location(F.key(1)) == .container(.wastebasket, order: 0))
        #expect(stage.state.wastebasket.swishes == 1, "a clean pass")
    }

    @Test("A drop slides with the hand's velocity and comes to rest; the rest commits once")
    func slideAndCommit() throws {
        let stage = try PhysicsStage(F.state(), physics: true)
        let from = try #require(stage.tokenPoint(F.key(1)))
        stage.drag(from, stage.point(core: 200, 214), steps: 30, pause: 6)
        stage.settle()
        let first = try #require(stage.location(F.key(1))?.pile)
        let start = try #require(stage.state.piles[first])
        // Picked up and let go moving right at 600 px/s (× 0.8): it keeps 0.3 of that and slides on about v/4 px.
        let grip = try #require(stage.tokenPoint(F.key(1)))
        stage.actions.removeAll()
        stage.drag(grip, grip + SIMD2(40, 0), steps: 4)
        stage.settle()
        let pile = try #require(stage.location(F.key(1))?.pile)
        let pos = try #require(stage.state.piles[pile])
        let body = try #require(stage.scene.pilePositions[pile])
        #expect(pos == body, "the resting position is committed")
        #expect(pos.x > start.x + 40 + 20 && pos.x < start.x + 40 + 50 && abs(pos.y - start.y) < 2,
                "slid on: \(start) → \(pos)")
        #expect(stage.state.piles.count == 1 && !stage.scene.needsFrames)
        let settles = stage.actions.filter { if case .pilesSettled = $0 { true } else { false } }
        #expect(settles.count == 1, "\(settles)")
    }

    @Test("Two identical scripted runs end with identical plane positions")
    func deterministic() throws {
        func run() throws -> [String] {
            let stage = try PhysicsStage(F.state(), physics: true)
            // Five piles set down, then flung sideways into each other and one forward off the front edge.
            for (k, x) in [(UInt64(1), 160), (2, 200), (3, 240), (4, 280), (5, 320)] {
                let from = try #require(stage.tokenPoint(F.key(k)))
                stage.drag(from, stage.point(core: x, 212), steps: 30, pause: 6)
            }
            stage.settle()
            for (k, dx, dy) in [(UInt64(1), Float(36), Float(0)), (5, -30, 4), (3, 6, 12), (2, 20, -3)] {
                let grip = try #require(stage.tokenPoint(F.key(k)))
                stage.drag(grip, grip + SIMD2(dx, dy), steps: 8)
                stage.frames(15)
            }
            stage.settle()
            return stage.scene.pilePositions.sorted { $0.key < $1.key }
                .map { "\($0.key.raw) \($0.value.x.bitPattern) \($0.value.y.bitPattern)" }
                + stage.state.tokens.sortedKeys.map { "\($0.inode) \(stage.state.tokens.location(of: $0)!)" }
        }
        let a = try run(), b = try run()
        #expect(a == b)
        #expect(a.contains { $0.contains("desk") })
    }
}
