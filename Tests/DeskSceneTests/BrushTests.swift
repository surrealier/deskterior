import DeskCore
import Foundation
import Metal
import simd
import Testing
@testable import DeskScene

@Suite("Desk brush (physics)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct BrushTests {
    typealias F = SceneFixture

    /// The canvas point that grabs the brush (its sprite's centre).
    func grip(_ stage: PhysicsStage) throws -> SIMD2<Float> {
        stage.centre(try #require(stage.scene.matAnchor("brush")))
    }

    @Test("Dragged, the brush shoves a pile into the mat's edge, where it tucks under; let go, it stops and commits")
    func sweepUnder() throws {
        let stage = try PhysicsStage(matDesk([[392, 24]]), physics: true, mat: true)
        stage.frames(3)
        let brush = try #require(stage.scene.room?.brushElement)
        let g = try grip(stage)
        #expect(stage.scene.hitTest(ArtPoint(Int(g.x), Int(g.y)))?.element == "brush")
        // Round behind the pile, then push it left into the mat.
        stage.drag(try grip(stage), stage.point(plane: [416, 26]), steps: 20, pause: 4)
        stage.drag(try grip(stage), stage.point(plane: [356, 26]), steps: 40, pause: 4)
        stage.settleMat()
        #expect(stage.mat.coversPile("P1") && stage.hub.bodies.ids.isEmpty, "swept under")
        #expect(stage.location(F.key(1))?.pile == "P1" && (stage.state.piles["P1"]?.x ?? 999) < 358)
        #expect(simd_distance(stage.state.brush.pos, brush.position) < 0.01, "the brush committed where it stopped")
        #expect(stage.state.brush.pos.x < 380 && stage.actions.contains { if case .brushSettled = $0 { true } else { false } })
        // A double-click sends it home.
        stage.click(try grip(stage), count: 2)
        stage.settleMat()
        #expect(stage.state.brush.pos == BrushState().pos && stage.scene.matExpectation("brush.home") == "true")
    }

    @Test("A sweep of 300 steps keeps every pile on the desk, under the mat, or properly gone over an edge")
    func longSweep() throws {
        let stage = try PhysicsStage(matDesk([[60, 20], [90, 40], [120, 70], [430, 30], [470, 80]]), physics: true, mat: true)
        stage.frames(3)
        let start = try grip(stage)
        var p = start
        stage.event(.move, p)
        stage.event(.down, p, count: 1)
        stage.frames(1)
        for k in 0..<300 {
            let t = Float(k) / 300 * 4 * .pi
            p = stage.point(plane: [256 + 220 * Float(cos(Double(t))), 52 + 40 * Float(sin(Double(2 * t)))])
            stage.event(.drag, p)
            stage.frames(1)
        }
        stage.event(.up, p, count: 1)
        stage.settleMat()
        let s = stage.state
        #expect(s.violations().isEmpty)
        let desk = DeskPlanePhysics.desk
        for id in s.tokens.piles {
            let q = try #require(s.piles[id])
            #expect(q.isFinite && q.x >= desk.x && q.x <= desk.x + desk.width && q.y >= desk.d && q.y <= desk.d + desk.depth)
        }
        for i in 1...5 {
            let loc = try #require(stage.location(F.key(UInt64(i))))
            switch loc {
            case .desk, .floor, .container(.wastebasket, _): break
            default: Issue.record("token \(i) ended at \(loc)")
            }
        }
    }

    @Test("The scroll-broom: a horizontal scroll over the bare desk sweeps a pile along, into the mat's edge")
    func scrollBroom() throws {
        let stage = try PhysicsStage(matDesk([[118, 28]]), physics: true, mat: true)
        stage.frames(3)
        let at = stage.point(plane: [98, 28])
        #expect(stage.scene.hitTest(DeskMatElement.pixel(at))?.part == "desk")
        for _ in 0..<4 {
            stage.scene.handle(InputEvent(.scroll, art: at, scroll: SIMD2(12, 0), t: stage.t))
            stage.frames(3)
        }
        #expect(stage.scene.room?.brushElement?.broomRun != nil)
        stage.settleMat()
        #expect(stage.scene.room?.brushElement?.broomRun == nil, "the broom stops once the scroll is still")
        #expect(stage.mat.coversPile("P1"), "pushed in under the left edge")
        // A vertical scroll there does nothing.
        stage.scene.handle(InputEvent(.scroll, art: at, scroll: SIMD2(0, 12), t: stage.t))
        #expect(stage.scene.room?.brushElement?.broomRun == nil)
    }
}
