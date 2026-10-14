import DeskCore
import Foundation
import Metal
import simd
import Testing
@testable import DeskScene

/// A desk whose tokens 1…n stand in piles at plane points (one token each, or `counts`), the rest on the monitor.
@MainActor
func matDesk(_ piles: [SIMD2<Float>], counts: [Int] = []) -> DeskState {
    var s = SceneFixture.state()
    var next: UInt64 = 1
    for (i, p) in piles.enumerated() {
        let id = PileID("P\(i + 1)")
        for k in 0..<(i < counts.count ? counts[i] : 1) {
            s.tokens.move(SceneFixture.key(next), to: .desk(pile: id, order: k))
            next += 1
        }
        s.piles[id] = p
    }
    return s
}

extension PhysicsStage {
    var mat: DeskMatElement { scene.room!.matElement! }

    /// The canvas point of desk-plane point `p` (on the desk top).
    func point(plane p: SIMD2<Float>, z: Float = 0) -> SIMD2<Float> {
        let o = layout.coreOrigin
        return DeskProjection.standard.project(SIMD3(p.x, p.y, z)) + SIMD2(Float(o.x), Float(o.y)) + 0.5
    }

    /// Frames until the mat (and everything else) is at rest, at most `limit`.
    func settleMat(limit: Int = 600) {
        var n = 0
        while (scene.needsFrames || !mat.cloth.isAsleep) && n < limit {
            frames(1)
            n += 1
        }
    }

    /// A drag with modifier keys held throughout (⌥ for the mat's transform), left held at `to`.
    func modDrag(_ from: SIMD2<Float>, _ to: SIMD2<Float>, steps: Int, mods: InputEvent.Modifiers) {
        event(.move, from, mods: mods)
        event(.down, from, count: 1, mods: mods)
        frames(1)
        for k in 1...steps {
            event(.drag, from + (to - from) * Float(k) / Float(steps), mods: mods)
            frames(1)
        }
    }
}

extension HoverStyle {
    var isNone: Bool { if case .none = self { true } else { false } }
}

@Suite("Desk mat (CPU)")
@MainActor
struct DeskMatSceneTests {
    typealias F = SceneFixture

    @Test("The bare room has no mat; with a model it draws itself, answers hits by part, and the bare desk band")
    func liveMat() throws {
        let bare = DeskScene(grid: PixelGrid(display: calibrationDisplay))
        let layout = try #require(bare.layout)
        #expect(bare.hitTest(layout.point(ArtPoint(170, 210)))?.element == "room")
        let scene = F.scene(matDesk([]))
        let mat = try #require(scene.room?.matElement)
        #expect(mat.isLive && scene.room?.elements.first { $0.id == "mat" }?.root.isHidden == true,
                "the bare room's keyboard shadow gives way to the raster")
        #expect(scene.hitTest(layout.point(ArtPoint(170, 210)))?.element == "mat")
        #expect(scene.hitTest(layout.point(ArtPoint(170, 210)))?.part == "mat")
        #expect(scene.hitTest(layout.point(ArtPoint(156, 210)))?.part == "mat.edge")
        #expect(scene.hitTest(layout.point(ArtPoint(157, 226)))?.part == "mat.corner")
        #expect(scene.hitTest(layout.point(ArtPoint(240, 206)))?.element == "keyboard", "the keyboard sits on top")
        let desk = try #require(scene.hitTest(layout.point(ArtPoint(100, 210))))
        #expect(desk.element == "mat" && desk.part == "desk")
        #expect(mat.hoverStyle(desk).isNone && mat.tooltip(desk) == nil)
        #expect(scene.contextMenu(at: layout.point(ArtPoint(100, 210))).item("clearDesk") != nil, "the desk menu")
        #expect(scene.contextMenu(at: layout.point(ArtPoint(170, 210))).item("peekUnder") != nil, "the mat's menu")
        // Behind the band (the back strip) the mat does not answer.
        #expect(scene.hitTest(layout.point(ArtPoint(100, 172)))?.element != "mat")
        // The keyboard is drawn where the mat holds it (its default spot).
        #expect(mat.keyboardRect == layout.rect(CoreLayout.keyboard))
        #expect(scene.matExpectation("mat.keyboard") == "254,52" && scene.matExpectation("mat.size") == "204x84")
    }

    @Test("Covered = hidden: a pile under the mat has no hit and shows as a bump; Visibility and the Inventory agree")
    func coveredIsHidden() throws {
        let scene = F.scene(matDesk([[300, 30], [440, 40]], counts: [3, 1]))
        let mat = try #require(scene.room?.matElement)
        #expect(mat.coversPile("P1") && !mat.coversPile("P2"))
        #expect(scene.matCoverage.coveredPiles == ["P1"])
        let s = try #require(scene.deskState)
        #expect(Visibility.of(s.tokens.location(of: F.key(1))!, s, scene.matCoverage).appearance == .bump)
        #expect(InventoryQuery.items(s, coverage: scene.matCoverage).first { $0.key == F.key(1) }?.label == "Under mat")
        #expect(scene.matExpectation("underMat") == "3" && scene.matExpectation("visible") == "\(s.tokens.count - 3)")
        #expect(mat.menuInfo().under.sorted() == [F.key(1), F.key(2), F.key(3)])
        let menu = try #require(scene.matMenu)
        #expect(menu.item("listUnder")?.isEnabled == true && menu.item("under.2") != nil)
    }

    @Test("matMode=flat: no peel or peek; bumps and covering stay; Reduce Motion flattens it too")
    func flatMode() throws {
        let scene = F.scene(matDesk([[300, 30]]))
        scene.matFlat = true
        let mat = try #require(scene.room?.matElement)
        #expect(mat.isFlat && mat.cloth.params.flatMode && scene.matExpectation("mat.mode") == "flat")
        #expect(scene.matMenu?.item("peekUnder")?.isEnabled == false)
        mat.perform(.peekUnder)
        #expect(!mat.cloth.isScriptRunning)
        #expect(mat.coversPile("P1"))
        scene.matFlat = false
        scene.reduceMotion = true
        #expect(mat.isFlat)
    }
}

@Suite("Desk mat (physics)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct DeskMatTests {
    typealias F = SceneFixture

    @Test("A token set down on the mat tucks under it (no body, a bump); more on that spot join it and the bump grows")
    func dropTucksUnder() throws {
        let stage = try PhysicsStage(matDesk([]), physics: true, mat: true)
        stage.frames(3)
        let drop = stage.point(plane: [320, 30])
        for k: UInt64 in [1, 2] {
            let from = try #require(stage.tokenPoint(F.key(k)))
            stage.drag(from, drop, steps: 12, pause: 6)
            stage.frames(4)
        }
        stage.settleMat()
        let id = try #require(stage.location(F.key(1))?.pile)
        #expect(stage.location(F.key(2))?.pile == id, "the second joined the covered pile")
        #expect(stage.mat.coversPile(id) && stage.hub.bodies.ids.isEmpty)
        #expect(stage.mat.bumps.groups.count == 1 && stage.mat.bumps.groups.first?.count == 2)
        let p = try #require(stage.state.piles[id])
        #expect(MatFootprint(cloth: stage.mat.cloth).isInside(p, inset: ClearDeskPlan.tuckInset - 0.5),
                "it rests well inside the edge: \(p)")
        #expect(stage.scene.deskTokenRect(F.key(1)) == nil && stage.scene.matTokenRect(F.key(1)) == nil)
        #expect(stage.mat.bumps.maxHeight >= BumpField.bumpHeight(count: 2) - 0.01)
        #expect(stage.actions.contains { if case .dropOnDesk = $0 { true } else { false } }, "a journaled drop")
    }

    @Test("Peek Under lifts the edge off a covered pile: it stands under the cloth and can be carried out")
    func peekAndTakeOut() throws {
        let stage = try PhysicsStage(matDesk([[320, 26]], counts: [2]), physics: true, mat: true)
        stage.frames(3)
        #expect(stage.mat.coversPile("P1"))
        stage.mat.lastHitPoint = stage.point(plane: [318, 14])
        stage.dispatch(.mat(.peekUnder))
        stage.frames(24)
        #expect(!stage.mat.coversPile("P1") && stage.hub.bodies.ids == ["P1"])
        #expect(stage.scene.matExpectation("revealed") == "2")
        // Under the lifted cloth the mat draws it (behind the flap); clear of it, the desk's piles do.
        let rect = try #require(stage.scene.matTokenRect(F.key(1)) ?? stage.scene.deskTokenRect(F.key(1)))
        #expect(stage.scene.hitTest(ArtPoint(rect.midX, rect.midY))?.part == "pile.P1")
        stage.drag(stage.centre(rect), stage.centre(stage.scene.screen!.cellRect(8, 4)), steps: 10)
        stage.settleMat()
        #expect(stage.location(F.key(1))?.isScreen == true && stage.location(F.key(2))?.isScreen == true)
        #expect(stage.mat.billboards.isEmpty && stage.scene.matExpectation("underMat") == "0")
    }

    @Test("A pile the cloth lifts off pops up over two frames (DESIGN §2.2 E9 hiding)")
    func revealPops() throws {
        let stage = try PhysicsStage(matDesk([[320, 26]], counts: [2]), physics: true, mat: true)
        stage.frames(3)
        stage.mat.lastHitPoint = stage.point(plane: [318, 14])
        stage.dispatch(.mat(.peekUnder))
        // Frame by frame from the reveal: the pop-up frame drawn (the mat's billboard or the desk's pile), then none.
        var seen: [Int?] = []
        for _ in 0..<60 where seen.count < 5 {
            stage.frames(1)
            if !seen.isEmpty || !stage.mat.coversPile("P1") { seen.append(stage.hub.revealPop("P1")) }
        }
        #expect(seen == [1, nil, nil, nil, nil] || seen == [0, 1, nil, nil, nil], "\(seen)")
        #expect(!stage.mat.coversPile("P1"))
    }

    @Test("Carrying the mat slides it over a pile (covered) and off it (revealed, its body back); the keyboard rides along")
    func carryCoversAndReveals() throws {
        let stage = try PhysicsStage(matDesk([[400, 50]]), physics: true, mat: true)
        stage.frames(3)
        #expect(!stage.mat.coversPile("P1") && stage.hub.bodies.ids == ["P1"])
        let grip = stage.point(plane: [330, 30])
        stage.drag(grip, grip + SIMD2(60, 0), steps: 30, pause: 10)
        stage.settleMat()
        #expect(stage.mat.coversPile("P1") && stage.hub.bodies.ids.isEmpty, "the mat slid over it")
        let kb = try #require(stage.state.mat.keyboard)
        #expect(kb.x > MatState.defaultKeyboard.x + 30, "the keyboard rode along: \(kb)")
        #expect((stage.mat.keyboardRect?.minX ?? 0) > stage.layout.rect(CoreLayout.keyboard).minX + 30)
        #expect(stage.state.mat.particles != nil && stage.scene.matExpectation("mat.saved") == "true")
        let back = stage.point(plane: [390, 30])
        stage.drag(back, back - SIMD2(70, 0), steps: 30, pause: 10)
        stage.settleMat()
        #expect(!stage.mat.coversPile("P1") && stage.hub.bodies.ids == ["P1"], "off again: on show with a body")
    }

    @Test("Folds and wrinkles survive a relaunch: the committed pose restores particle for particle")
    func persistence() throws {
        let stage = try PhysicsStage(matDesk([[250, 20]]), physics: true, mat: true)
        stage.frames(3)
        // Peel the front-right corner back past the middle and let go: it stays folded.
        let corner = try #require(stage.scene.matAnchor("mat.corner.se"))
        stage.drag(stage.centre(corner), stage.point(core: 334, 186), steps: 40)
        stage.settleMat()
        #expect(ClothMetrics.foldedCount(stage.mat.cloth) > 0 && stage.scene.matExpectation("mat.saved") == "true")
        // Through desk.json and back.
        let data = try DeskDocument(state: stage.state, savedAt: F.t0).encoded()
        var loaded = try DeskDocument.decode(data).makeState()
        loaded.access = .connected
        let relaunched = try PhysicsStage(loaded, physics: true, mat: true)
        relaunched.frames(2)
        let a = stage.mat.cloth.positions, b = relaunched.mat.cloth.positions
        #expect(a.count == b.count && zip(a, b).allSatisfy { simd_distance($0, $1) < 0.01 })
        #expect(ClothMetrics.foldedCount(relaunched.mat.cloth) == ClothMetrics.foldedCount(stage.mat.cloth))
        #expect(relaunched.mat.cloth.isAsleep && relaunched.mat.coversPile("P1") == stage.mat.coversPile("P1"))
    }

    @Test("At rest the mat costs nothing: no frames, no renders, no uploads; a knock wakes it and it sleeps again")
    func idle() throws {
        let stage = try PhysicsStage(matDesk([[300, 30]]), physics: true, mat: true)
        stage.settleMat()
        #expect(!stage.mat.needsFrames && !stage.scene.needsFrames)
        let texture = stage.mat.surfaceTexture
        stage.frames(10)
        #expect(stage.mat.surfaceTexture === texture, "nothing re-uploaded while asleep")
        stage.click(stage.point(core: 150, 238), count: 2)
        stage.frames(2)
        #expect(!stage.mat.cloth.isAsleep)
        stage.settleMat()
        #expect(stage.mat.cloth.isAsleep && !stage.scene.needsFrames)
    }

    @Test("⌥-drag a corner: handles show and the mat turns and grows as far as it fits; flaps unfold, edges smooth")
    func transformSmoothUnfold() throws {
        let stage = try PhysicsStage(matDesk([]), physics: true, mat: true)
        stage.frames(3)
        let corner = try #require(stage.scene.matAnchor("mat.corner.ne"))
        let to = stage.centre(corner) + SIMD2(30, -10)
        stage.modDrag(stage.centre(corner), to, steps: 20, mods: [.option])
        #expect(stage.mat.showsHandles && stage.mat.cloth.grabMode == .transform)
        stage.event(.up, to, count: 1, mods: [.option])
        stage.settleMat()
        #expect(!stage.mat.showsHandles && stage.mat.cloth.restSize.x > 204)
        stage.dispatch(.mat(.reset))
        stage.settleMat()
        // A fold, then a double-click on the flap unfolds it.
        let se = try #require(stage.scene.matAnchor("mat.corner.se"))
        stage.drag(stage.centre(se), stage.point(core: 334, 186), steps: 40)
        stage.settleMat()
        #expect(ClothMetrics.foldedCount(stage.mat.cloth) > 0)
        let flap = try #require(stage.scene.matAnchor("mat.flap"))
        #expect(stage.scene.hitTest(ArtPoint(flap.midX, flap.midY))?.part == "mat.flap")
        stage.click(stage.centre(flap), count: 2)
        stage.settleMat()
        #expect(ClothMetrics.foldedCount(stage.mat.cloth) == 0)
        // Wrinkle it with a fast carry, then a double-click on an edge smooths it.
        let grip = stage.point(plane: [200, 30])
        stage.drag(grip, grip + SIMD2(40, -10), steps: 6)
        stage.settleMat()
        let wrinkled = ClothMetrics.wrinkle(stage.mat.cloth)
        let edge = try #require(stage.scene.matAnchor("mat.edge.e"))
        stage.click(stage.centre(edge), count: 2)
        stage.settleMat()
        #expect(ClothMetrics.wrinkle(stage.mat.cloth) <= wrinkled)
    }
}

/// Release benchmark of the mat's whole awake frame in the scene (`scripts/swift-test.sh -c release --filter
/// MatFramePerf`): cloth step, coverage, bumps, raster and upload. Asserted only in optimized builds.
@Suite("MatFramePerf", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct MatFramePerfTests {
    #if DEBUG
    static let optimized = false
    #else
    static let optimized = true
    #endif

    @Test("An awake mat frame (carried over covered piles) fits its share of the frame budget")
    func frame() throws {
        let stage = try PhysicsStage(matDesk([[190, 40], [252, 52], [318, 44], [420, 30]], counts: [1, 3, 7, 1]),
                                     physics: true, mat: true)
        stage.frames(3)
        let mat = stage.mat
        let grip = stage.point(plane: [200, 30])
        stage.event(.move, grip)
        stage.event(.down, grip, count: 1)
        stage.frames(1)
        var samples: [Double] = []
        for k in 0..<121 {
            stage.event(.drag, grip + SIMD2(20 * Float(sin(Double(k) * 0.1)), 0))
            let t0 = DispatchTime.now().uptimeNanoseconds
            mat.step(1.0 / 60)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        print(String(format: "MatFramePerf (%@): awake mat frame %.3f ms (median of 121)",
                     Self.optimized ? "release" : "debug", median))
        if Self.optimized { #expect(median <= 1.6) }
    }
}
