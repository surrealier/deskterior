import DeskCore
import Foundation
import Metal
import simd
import SpriteKit
import Testing
@testable import DeskScene

@Suite("Clear the Desk in the scene (physics)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct ClearDeskTests {
    typealias F = SceneFixture

    /// Piles left and right of the mat, a floor stack, an open drawer and the phone face up.
    static func busy() -> DeskState {
        var s = matDesk([[100, 36], [420, 30]], counts: [2, 1])
        s.tokens.move(F.key(4), to: .floor(x: 130))
        s.tokens.move(F.key(5), to: .container(.riserLeft, order: 0))
        s.drawers[.riserLeft] = DrawerState(p: 10)
        return s
    }

    @Test("The pass: held piles show only as stand-ins until they are under; then bumps, TIDY!, the brush home")
    func pass() throws {
        let stage = try PhysicsStage(Self.busy(), physics: true, mat: true)
        stage.frames(3)
        let mat = try #require(stage.scene.room?.matElement)
        let brush = try #require(stage.scene.room?.brushElement)
        #expect(stage.hub.bodies.ids.count == 2)
        stage.dispatch(.clearDesk)
        let run = try #require(mat.clearRun)
        let held = Set(run.plan.sweeps.map(\.pile) + run.plan.tucks.map(\.pile))
        #expect(held.count == 3 && held.allSatisfy(mat.coversPile))
        #expect(stage.hub.bodies.ids.isEmpty, "piles under the mat (or on their way) have no body")
        #expect(mat.bumps.groups.isEmpty && mat.billboards.isEmpty, "no bump until a pile is under")
        stage.frames(20)
        #expect(brush.scripted != nil && brush.position != BrushState().pos, "the brush is out on its pass")
        var n = 0
        while mat.clearRun != nil && n < 400 {
            stage.frames(1)
            n += 1
        }
        #expect(mat.clearRun == nil && n < 300, "the pass took \(n) frames")
        #expect(stage.scene.room!.context.fx.count > 0, "TIDY! pops as the pass ends")
        #expect(brush.scripted == nil && simd_distance(brush.position, BrushState().pos) < 0.01)
        stage.settle()
        #expect(mat.coveredPiles == Set(stage.state.tokens.piles) && mat.bumps.groups.count >= 2)
        #expect(stage.scene.matExpectation("visible") == "0" && stage.scene.matExpectation("underMat") == "4")
    }

    @Test("Undo brings the piles back where they were, with their bodies; redo hides them again at once")
    func undoRedo() throws {
        let stage = try PhysicsStage(Self.busy(), physics: true, mat: true)
        stage.frames(3)
        let before = stage.state
        stage.dispatch(.clearDesk)
        stage.scene.forceRest()
        #expect(stage.scene.room?.matElement?.clearRun == nil)
        stage.dispatch(.undo)
        stage.frames(3)
        #expect(stage.state.tokens == before.tokens && stage.state.piles == before.piles)
        #expect(stage.state.monitor == before.monitor && stage.state.phone == before.phone)
        #expect(stage.state.drawers == before.drawers)
        #expect(Set(stage.hub.bodies.ids) == Set(before.piles.keys))
        #expect(stage.hub.bodies.positions == before.piles, "back exactly where they lay")
        stage.dispatch(.redo)
        stage.frames(2)
        #expect(stage.hub.bodies.ids.isEmpty && stage.scene.matExpectation("visible") == "0")
    }

    @Test("An undo while the pass plays stops it: the piles are back on show where they were, no stand-ins left")
    func undoMidPass() throws {
        let stage = try PhysicsStage(Self.busy(), physics: true, mat: true)
        stage.frames(3)
        stage.dispatch(.clearDesk)
        stage.frames(20)
        stage.dispatch(.undo)
        stage.frames(2)
        let mat = stage.mat
        #expect(mat.clearRun == nil && stage.scene.room?.brushElement?.scripted == nil)
        #expect(Set(stage.hub.bodies.ids) == ["P1", "P2"] && mat.coveredPiles.isEmpty)
        #expect(mat.root.children.filter { $0 is SKSpriteNode && !$0.isHidden }.count <= 2, "only the surface (and handles)")
    }

    @Test("With Reduce Motion everything is under at once (a puff each)")
    func reduceMotion() throws {
        let stage = try PhysicsStage(Self.busy(), physics: true, mat: true)
        stage.scene.reduceMotion = true
        stage.frames(2)
        stage.dispatch(.clearDesk)
        stage.frames(1)
        let mat = try #require(stage.scene.room?.matElement)
        #expect(mat.clearRun == nil && mat.coveredPiles == Set(stage.state.tokens.piles))
    }
}
