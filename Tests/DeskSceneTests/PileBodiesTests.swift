import DeskCore
import Foundation
import Metal
import simd
import Testing
@testable import DeskScene

/// A desk with tokens 1…n in piles at plane points (one token per pile), the rest on the monitor.
private func pileDesk(_ piles: [SIMD2<Float>]) -> DeskState {
    var s = SceneFixture.state()
    for (i, p) in piles.enumerated() {
        let id = PileID("P\(i + 1)")
        s.tokens.move(SceneFixture.key(UInt64(i + 1)), to: .desk(pile: id, order: 0))
        s.piles[id] = p
    }
    return s
}

@Suite("Pile bodies (CPU)")
struct PileBodiesUnitTests {
    @Test("Bodies follow the model: restored piles start frozen; a pile the model moves gets a new body there")
    func sync() {
        let bodies = PileBodies(world: DeskPlaneWorld())
        bodies.sync(["P1": [100, 50], "P2": [300, 80]])
        #expect(bodies.ids == ["P1", "P2"] && bodies.freezer.isFrozen("P1") && !bodies.isMoving)
        #expect(bodies.world.position(of: "P1") == [100, 50])
        bodies.sync(["P1": [120, 60], "P2": [300, 80]])
        #expect(bodies.world.position(of: "P1") == [120, 60], "undo moved it: a new body there")
        bodies.sync(["P2": [300, 80]])
        #expect(bodies.ids == ["P2"])
        // A pile the scene makes moves at once and is dynamic.
        bodies.add("P9", at: [200, 40], velocity: [100, 0])
        #expect(bodies.isMoving && !bodies.freezer.isFrozen("P9") && bodies.world.isDynamic("P9"))
    }

    @Test("After a step: a centre past an open edge leaves on an arc; NaN snaps; resting piles report once")
    func afterStep() {
        let bodies = PileBodies(world: DeskPlaneWorld())
        bodies.add("P1", at: [200, 40])
        bodies.add("P2", at: [300, 40])
        bodies.add("P3", at: [150, 90])
        bodies.world.piles["P2"]?.position = DeskPlaneWorld.scenePoint([300, -1])
        bodies.world.piles["P3"]?.position = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        let r = bodies.afterStep(1.0 / 60, obstacles: [])
        #expect(r.pushedOff.map(\.pile) == ["P2"] && bodies.launched == ["P2"] && bodies.world.piles["P2"] == nil)
        #expect(r.snapped.map(\.pile) == ["P3"] && r.snapped.first?.reason == .notFinite)
        #expect(r.settled["P3"].map { $0.isFinite } == true, "snapped to a valid spot and committed")
        // P1 never moved: nothing to commit, and it no longer counts as moving.
        #expect(r.settled["P1"] == nil && !bodies.isMoving)
        let again = bodies.afterStep(1.0 / 60, obstacles: [])
        #expect(again.isEmpty)
    }

    @Test("Speeds are clamped to 1200 px/s; hard sleep freezes every body")
    func clampAndFreeze() {
        let bodies = PileBodies(world: DeskPlaneWorld())
        bodies.add("P1", at: [200, 40], velocity: [3000, 0])
        _ = bodies.afterStep(1.0 / 60, obstacles: [])
        #expect(abs(simd_length(bodies.world.velocity(of: "P1")) - 1200) < 1)
        _ = bodies.freezeAll()
        #expect(bodies.freezer.isFrozen("P1") && !bodies.world.isDynamic("P1") && !bodies.isMoving)
    }
}

@Suite("Pile bodies (physics)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct PileBodiesTests {
    typealias F = SceneFixture

    @Test("A pile slid over the front edge flies off and lands on the floor; over the basket, in it")
    func pushOff() throws {
        let stage = try PhysicsStage(pileDesk([[300, 8], [64, 2]]), physics: true)
        stage.hub.bodies.world.setDynamic("P1", true)
        stage.hub.bodies.world.setDynamic("P2", true)
        stage.hub.bodies.world.setVelocity("P1", [20, -200])
        stage.hub.bodies.world.setVelocity("P2", [0, -40])
        stage.frames(2)
        stage.settle()
        guard case let .floor(x)? = stage.location(F.key(1)) else {
            Issue.record("expected the floor: \(String(describing: stage.location(F.key(1))))")
            return
        }
        #expect(x > 295 && x < 340 && FloorLine.isFree(x))
        #expect(stage.location(F.key(2)) == .container(.wastebasket, order: 0))
        #expect(stage.state.piles.isEmpty && stage.scene.pilePositions.isEmpty)
        #expect(stage.journal.undoLabel == nil, "scene motion is not an undoable move")
    }

    @Test("Resting piles freeze after 2 s; a pile sliding into a frozen one thaws it and both commit")
    func freezeAndThaw() throws {
        let stage = try PhysicsStage(pileDesk([[200, 90]]), physics: true)
        let bodies = stage.hub.bodies
        #expect(bodies.freezer.isFrozen("P1"), "restored piles start frozen")
        stage.hub.landOnDesk([F.key(2)], at: [150, 90], velocity: [400, 0], journaled: false)
        let mover = try #require(stage.location(F.key(2))?.pile)
        stage.settle()
        let p1 = try #require(stage.state.piles["P1"]), p2 = try #require(stage.state.piles[mover])
        #expect(p1.x > 201, "the frozen pile thawed and was shoved: \(p1)")
        #expect(p2.x < p1.x && stage.scene.pilePositions["P1"] == p1)
        stage.frames(150)
        #expect(bodies.freezer.isFrozen("P1") && bodies.freezer.isFrozen(mover), "2 s at rest")
    }

    @Test("An undone drop puts the pile's body back where the model has it")
    func undoMovesBody() throws {
        let stage = try PhysicsStage(F.state(), physics: true)
        let from = try #require(stage.tokenPoint(F.key(1)))
        stage.drag(from, stage.point(core: 250, 214), steps: 30, pause: 6)
        stage.settle()
        let first = try #require(stage.location(F.key(1))?.pile)
        let firstPos = try #require(stage.state.piles[first])
        let grip = try #require(stage.tokenPoint(F.key(1)))
        stage.drag(grip, grip + SIMD2(60, 0), steps: 30, pause: 6)
        stage.settle()
        let moved = try #require(stage.location(F.key(1))?.pile)
        #expect(stage.state.piles[moved]!.x > firstPos.x + 50)
        stage.dispatch(.undo)
        stage.frames(2)
        let back = try #require(stage.location(F.key(1))?.pile)
        let body = try #require(stage.scene.pilePositions[back])
        // The body sits where the model has it (Box2D keeps positions in metres: equal to within float rounding).
        #expect(stage.state.piles[back] == firstPos && simd_length(body - firstPos) < 0.001, "\(body) vs \(firstPos)")
    }
}
