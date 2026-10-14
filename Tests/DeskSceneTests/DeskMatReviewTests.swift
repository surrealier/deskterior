import DeskCore
import Foundation
import Metal
import simd
import SpriteKit
import Testing
@testable import DeskScene

/// A desk whose tokens 1…n stand in piles of `counts` at plane points, with 60 files in all.
@MainActor
func busyMatDesk(_ piles: [SIMD2<Float>], counts: [Int]) -> DeskState {
    var s = SceneFixture.state((1...60).map { "file \($0).txt" })
    var next: UInt64 = 1
    for (i, p) in piles.enumerated() {
        let id = PileID("P\(i + 1)")
        for k in 0..<counts[i] {
            s.tokens.move(SceneFixture.key(next), to: .desk(pile: id, order: k))
            next += 1
        }
        s.piles[id] = p
    }
    return s
}

/// The M9 review's fixes in the scene: undo stays exact, nothing hides under the keyboard, Show on Desk always shows,
/// quitting mid-motion, flat mode, saved wrecks, the broom, the keyboard, piles picked out, ⌥ handles, going under.
@Suite("Desk mat review (physics)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct DeskMatReviewTests {
    typealias F = SceneFixture

    // MARK: Undo

    @Test("Clear the Desk next to covered piles: the scene moves nothing after the action, and one undo is exact")
    func clearDeskUndoExact() throws {
        let stage = try PhysicsStage(busyMatDesk([[250, 2], [250, 26]], counts: [3, 3]), physics: true, mat: true)
        stage.frames(3)
        stage.settleMat()
        let before = stage.state
        stage.dispatch(.clearDesk)
        let after = stage.state
        stage.settleMat(limit: 1200)
        #expect(stage.state.piles == after.piles, "no pile moved outside the journal: \(after.piles) → \(stage.state.piles)")
        let keep = ClearDeskPlan.keyboardClearance(stage.state.mat.keyboardFootprint)
        #expect(stage.state.piles.values.allSatisfy { !keep.contains($0) })
        stage.dispatch(.undo)
        stage.frames(3)
        #expect(stage.state.piles == before.piles && stage.state.tokens == before.tokens)
    }

    @Test("A drop on a covered pile joins it and slides it in, in the one journaled move; undo puts it back")
    func dropJoinUndo() throws {
        let stage = try PhysicsStage(busyMatDesk([[320, 26]], counts: [3]), physics: true, mat: true)
        stage.frames(3)
        stage.settleMat()
        let before = stage.state
        let from = try #require(stage.tokenPoint(F.key(10)))
        stage.drag(from, stage.point(plane: [320, 26]), steps: 12, pause: 6)
        stage.settleMat()
        #expect(stage.location(F.key(10))?.pile == "P1")
        #expect(stage.actions.contains { if case .tuckUnderMat = $0 { true } else { false } })
        #expect(!stage.actions.contains { if case .pilesSettled = $0 { true } else { false } })
        let p = try #require(stage.state.piles["P1"])
        #expect(MatFootprint(cloth: stage.mat.cloth).isInside(p, inset: ClearDeskPlan.inset(count: 4) - 0.01))
        stage.dispatch(.undo)
        stage.frames(3)
        #expect(stage.state.piles == before.piles && stage.state.tokens == before.tokens)
    }

    @Test("Drops on one spot keep joining the pile under it as it slides in (one bump)")
    func dropsKeepJoining() throws {
        let stage = try PhysicsStage(busyMatDesk([], counts: []), physics: true, mat: true)
        stage.frames(3)
        let drop = stage.point(plane: [320, 24])
        for k: UInt64 in 1...7 {
            let from = try #require(stage.tokenPoint(F.key(k)))
            stage.drag(from, drop, steps: 10, pause: 6)
            stage.settleMat()
        }
        #expect(stage.mat.bumps.groups.count == 1 && stage.state.tokens.piles.count == 1)
    }

    // MARK: The keyboard

    @Test("A drop on the keyboard lands beside it, under the mat, where a peek can reach it")
    func dropOnKeyboard() throws {
        let stage = try PhysicsStage(busyMatDesk([], counts: []), physics: true, mat: true)
        stage.frames(3)
        let kb = try #require(stage.mat.keyboardRect)
        let from = try #require(stage.tokenPoint(F.key(1)))
        stage.drag(from, stage.centre(kb), steps: 12, pause: 6)
        stage.settleMat()
        let id = try #require(stage.location(F.key(1))?.pile)
        let p = try #require(stage.state.piles[id])
        #expect(!ClearDeskPlan.keyboardClearance(stage.state.mat.keyboardFootprint).contains(p), "\(p)")
        #expect(stage.mat.coversPile(id))
        stage.dispatch(.showOnDesk(F.key(1)))
        var revealed = false
        for _ in 0..<60 where !revealed {
            stage.frames(1)
            revealed = !stage.mat.coversPile(id)
        }
        #expect(revealed)
    }

    @Test("Carried so the keyboard comes to rest over a covered pile, the mat lets the pile out from under it")
    func keyboardOverPile() throws {
        let stage = try PhysicsStage(busyMatDesk([[400, 52]], counts: [2]), physics: true, mat: true)
        stage.frames(3)
        let grip = stage.point(plane: [330, 30])
        stage.drag(grip, grip + SIMD2(146, 0), steps: 60, pause: 10)
        stage.settleMat(limit: 900)
        stage.frames(5)
        let p = try #require(stage.state.piles["P1"])
        #expect(stage.mat.coversPile("P1"))
        #expect(!ClearDeskPlan.keyboardClearance(stage.state.mat.keyboardFootprint).contains(p), "\(p)")
        stage.dispatch(.showOnDesk(F.key(1)))
        var revealed = false
        for _ in 0..<90 where !revealed {
            stage.frames(1)
            revealed = !stage.mat.coversPile("P1")
        }
        #expect(revealed)
    }

    @Test("At rest the keyboard is drawn where a relaunch draws it")
    func keyboardPixelAfterRelaunch() throws {
        let stage = try PhysicsStage(busyMatDesk([], counts: []), physics: true, mat: true)
        stage.frames(3)
        let grip = stage.point(plane: [200, 30])
        stage.drag(grip, grip + SIMD2(23, -3), steps: 17, pause: 6)
        stage.settleMat()
        let rect = try #require(stage.mat.keyboardRect)
        let relaunched = try PhysicsStage(stage.state, physics: true, mat: true)
        relaunched.frames(3)
        #expect(relaunched.mat.keyboardRect == rect)
    }

    @Test("The keyboard is part of the mat: a drag on it carries the mat, its menu is the mat's")
    func keyboardCarriesMat() throws {
        let stage = try PhysicsStage(busyMatDesk([], counts: []), physics: true, mat: true)
        stage.frames(3)
        let kb = try #require(stage.mat.keyboardRect)
        let start = try #require(stage.mat.cloth.keyboardCenter)
        stage.drag(stage.centre(kb), stage.centre(kb) + SIMD2(30, 0), steps: 15, hold: true)
        #expect(stage.mat.cloth.grabMode == .carry)
        stage.event(.up, stage.centre(kb) + SIMD2(30, 0), count: 1)
        stage.settleMat()
        let end = try #require(stage.mat.cloth.keyboardCenter)
        #expect(end.x - start.x > 20, "\(start) → \(end)")
        let moved = try #require(stage.mat.keyboardRect)
        #expect(stage.scene.contextMenu(at: ArtPoint(moved.midX, moved.midY)).item("peekUnder") != nil)
    }

    // MARK: Show on Desk

    @Test("Show on Desk on a token under the mat: the edge peeks up, the token is selected and blinks for 2 s")
    func showOnDeskPulses() throws {
        let stage = try PhysicsStage(busyMatDesk([[320, 26]], counts: [2]), physics: true, mat: true)
        stage.frames(3)
        stage.settleMat()
        let room = try #require(stage.scene.room)
        stage.dispatch(.showOnDesk(F.key(1)))
        var selected = 0, shown = 0
        for _ in 0..<150 {
            stage.frames(1)
            if room.context.selection.contains(F.key(1)) { selected += 1 }
            if !stage.mat.coversPile("P1") { shown += 1 }
        }
        #expect(selected > 100 && shown >= 120, "selected \(selected), shown \(shown) frames")
        stage.settleMat()
        #expect(stage.mat.coversPile("P1"), "and lies back after")
    }

    @Test("Show on Desk with flat cloth (matMode=flat, Reduce Motion): the pile is shown over it, picked, for a while")
    func showOnDeskFlat() throws {
        for reduce in [false, true] {
            let stage = try PhysicsStage(busyMatDesk([[320, 26]], counts: [1]), physics: true, mat: true)
            if reduce { stage.scene.reduceMotion = true } else { stage.scene.matFlat = true }
            stage.frames(3)
            #expect(stage.mat.coversPile("P1"))
            stage.dispatch(.showOnDesk(F.key(1)))
            stage.frames(10)
            #expect(!stage.mat.coversPile("P1"))
            let rect = try #require(stage.scene.matTokenRect(F.key(1)) ?? stage.scene.deskTokenRect(F.key(1)))
            #expect(stage.scene.hitTest(ArtPoint(rect.midX, rect.midY))?.token == F.key(1))
            #expect(stage.scene.room!.context.selection.contains(F.key(1)))
            stage.frames(200)
            stage.settleMat()
            #expect(stage.mat.coversPile("P1"), "covered again afterwards")
        }
    }

    // MARK: Settle

    @Test("Quit mid-peek, mid-peel or mid-resize: the saved pose lies on the desk, at a size on the grid")
    func settleMidMotion() throws {
        let peek = try PhysicsStage(busyMatDesk([[320, 26]], counts: [1]), physics: true, mat: true)
        peek.frames(3)
        peek.mat.lastHitPoint = peek.point(plane: [318, 14])
        peek.dispatch(.mat(.peekUnder))
        peek.frames(30)
        peek.scene.forceRest()
        // Over the pile's bump (3 px) the felt stands 4 px; nothing stands in the air.
        var z = (MatState.decodeParticles(peek.state.mat.particles ?? "", count: 525) ?? []).map(\.z)
        #expect((z.max() ?? 99) < 5.5, "peek: \(z.max() ?? -1)")
        #expect(ClothMetrics.maxLift(peek.mat.cloth) < 1 && peek.mat.coversPile("P1"))
        #expect(peek.scene.matExpectation("mat.saved") == "true")

        let peel = try PhysicsStage(busyMatDesk([], counts: []), physics: true, mat: true)
        peel.frames(3)
        let edge = try #require(peel.scene.matAnchor("mat.edge.s"))
        peel.drag(peel.centre(edge), peel.centre(edge) + SIMD2(0, -20), steps: 20, hold: true)
        peel.scene.cancelInput()
        peel.scene.forceRest()
        z = (MatState.decodeParticles(peel.state.mat.particles ?? "", count: 525) ?? []).map(\.z)
        #expect((z.max() ?? 99) < 2, "peel: \(z.max() ?? -1)")

        let resize = try PhysicsStage(busyMatDesk([], counts: []), physics: true, mat: true)
        resize.frames(3)
        resize.dispatch(.mat(.size(.large)))
        resize.frames(5)
        resize.scene.forceRest()
        let size = resize.state.mat.size
        #expect(!resize.mat.cloth.isTransforming)
        #expect(size.x.truncatingRemainder(dividingBy: 6) == 0 && size.y.truncatingRemainder(dividingBy: 6) == 0, "\(size)")
    }

    @Test("A fold made before Reduce Motion lies back when it turns on; Unfold stays available")
    func foldThenFlat() throws {
        let stage = try PhysicsStage(busyMatDesk([], counts: []), physics: true, mat: true)
        stage.frames(3)
        let se = try #require(stage.scene.matAnchor("mat.corner.se"))
        stage.drag(stage.centre(se), stage.point(core: 334, 186), steps: 40)
        stage.settleMat()
        #expect(ClothMetrics.foldedCount(stage.mat.cloth) > 0)
        stage.scene.reduceMotion = true
        stage.frames(2)
        stage.settleMat()
        #expect(ClothMetrics.foldedCount(stage.mat.cloth) == 0)
        #expect(stage.scene.matExpectation("mat.saved") == "true")
    }

    @Test("A saved wreck of a mat (finite but far off the desk) lays a fresh mat")
    func wreckedSave() throws {
        var s = busyMatDesk([[300, 30]], counts: [1])
        var pos = ClothSim().positions
        for i in pos.indices { pos[i] = SIMD3(-1e30, pos[i].y, 1e30) }
        s.mat.particles = MatState.encodeParticles(pos)
        let stage = try PhysicsStage(s, physics: true, mat: true)
        stage.frames(3)
        #expect(stage.scene.matExpectation("mat.size") == "204x84" && stage.mat.bounds.w > 150)
        #expect(stage.mat.coversPile("P1"))
    }

    // MARK: Gestures

    @Test("The scroll-broom starts behind a pile under the pointer and pushes it the way of the scroll")
    func broomBehindPile() throws {
        let stage = try PhysicsStage(busyMatDesk([[100, 40]], counts: [2]), physics: true, mat: true)
        stage.frames(3)
        stage.settleMat()
        let at = stage.point(plane: [100, 40])
        let start = try #require(stage.hub.world.position(of: "P1"))
        stage.scene.handle(InputEvent(.scroll, art: at, scroll: SIMD2(2, 0), t: stage.t))
        var least = start.x
        for _ in 0..<30 {
            stage.frames(1)
            if let p = stage.hub.world.position(of: "P1") { least = min(least, p.x) }
        }
        #expect(least > start.x - 0.5, "never knocked backwards: \(start.x) → \(least)")
        #expect(BrushElement.broomStart(SIMD2(100, 40), dx: 2, piles: [SIMD2(100, 40)]).x < 100 - 9)
        #expect(BrushElement.broomStart(SIMD2(100, 40), dx: -2, piles: [SIMD2(100, 40)]).x > 100 + 9)
    }

    @Test("From a pile under lifted cloth a drag takes the front token; ⇧ takes the pile; a double-click opens one")
    func pickOutOneToken() throws {
        let stage = try PhysicsStage(busyMatDesk([[320, 26]], counts: [3]), physics: true, mat: true)
        stage.frames(3)
        stage.mat.lastHitPoint = stage.point(plane: [318, 14])
        stage.dispatch(.mat(.peekUnder))
        stage.frames(24)
        let rect = try #require(stage.scene.matTokenRect(F.key(3)) ?? stage.scene.deskTokenRect(F.key(3)))
        stage.drag(stage.centre(rect), stage.centre(stage.scene.screen!.cellRect(8, 4)), steps: 10)
        stage.frames(3)
        #expect(stage.location(F.key(3))?.isScreen == true, "the front (top) token came out")
        #expect(stage.location(F.key(1))?.pile == "P1" && stage.location(F.key(2))?.pile == "P1")
    }

    @Test("⌥ held over the mat shows its handles without a move; letting go hides them")
    func optionHover() throws {
        let stage = try PhysicsStage(busyMatDesk([], counts: []), physics: true, mat: true)
        stage.frames(3)
        let centre = stage.point(plane: [180, 30])
        stage.event(.move, centre)
        #expect(stage.scene.matExpectation("mat.handles") == "false")
        stage.event(.move, centre, mods: [.option])
        #expect(stage.scene.matExpectation("mat.handles") == "true")
        stage.event(.move, centre)
        #expect(stage.scene.matExpectation("mat.handles") == "false")
        let hit = try #require(stage.scene.hitTest(DeskMatElement.pixel(centre)))
        let tip = try #require(stage.mat.tooltip(hit))
        #expect(tip.detail?.contains("⌥") == true)
        // Over the keyboard (which lies on the mat) too.
        let kb = stage.centre(try #require(stage.mat.keyboardRect))
        stage.event(.move, kb)
        stage.event(.move, kb, mods: [.option])
        #expect(stage.scene.matExpectation("mat.handles") == "true")
        stage.event(.move, centre + SIMD2(0, 200))
        #expect(stage.scene.matExpectation("mat.handles") == "false")
    }

    // MARK: Going under

    @Test("A pile pushed into the mat's edge slips under it: drawn clipped at the edge, no squash, its bump slides in")
    func slidesUnder() throws {
        let stage = try PhysicsStage(busyMatDesk([[392, 24]], counts: [1]), physics: true, mat: true)
        stage.frames(3)
        func grip() throws -> SIMD2<Float> { stage.centre(try #require(stage.scene.matAnchor("brush"))) }
        stage.drag(try grip(), stage.point(plane: [416, 26]), steps: 20, pause: 4)
        let from = try grip(), to = stage.point(plane: [356, 26])
        stage.event(.move, from)
        stage.event(.down, from, count: 1)
        stage.frames(1)
        var entering = false, squashes = 0
        for k in 1...40 {
            stage.event(.drag, from + (to - from) * Float(k) / 40)
            stage.frames(1)
            if stage.mat.billboards["P1"]?.entering == true { entering = true }
            squashes = max(squashes, stage.mat.root.children.filter { $0 is SKSpriteNode && $0 !== stage.mat.handles }.count - 1)
        }
        stage.event(.up, to, count: 1)
        stage.settleMat()
        #expect(entering, "the edge slid over its card")
        #expect(squashes == 0, "no squashed card over the felt")
        #expect(stage.mat.coversPile("P1") && stage.mat.bumps.groups.count == 1)
    }
}
