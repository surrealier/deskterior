import DeskCore
import DeskPixels
import Metal
import SpriteKit
import Testing
@testable import DeskScene

/// The v0.1.0 release review's fixes in the scene (Erratum 28): mat commands during a peek, the keyboard's cover after
/// a widget nudge, a flat mat that adopts a folded save, and monitor cards that follow the language.
@Suite("Release review (scene, physics)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct ReleaseReviewSceneTests {
    typealias F = SceneFixture

    /// Setup commands, then the command picked while a peek is up.
    nonisolated static let transforms: [([MatCommand], MatCommand)] = [
        ([.size(.small)], .rotate(degrees: 15)), ([], .rotate(degrees: -15)), ([], .size(.large)), ([], .size(.small)),
        ([.rotate(degrees: 15)], .straighten),
    ]

    /// The mat after `setup`, an optional Peek Under left running 20 frames, then `command`, at rest: its angle, size,
    /// whether it is folded or wrinkled, and whether that pose is what the model saved.
    func outcome(peek: Bool, setup: [MatCommand], _ command: MatCommand) throws -> [String?] {
        let stage = try PhysicsStage(busyMatDesk([], counts: []), physics: true, mat: true)
        stage.frames(3)
        for c in setup {
            stage.dispatch(.mat(c))
            stage.settleMat()
        }
        if peek {
            stage.mat.lastHitPoint = nil
            stage.dispatch(.mat(.peekUnder))
            stage.frames(20)
            #expect(stage.mat.cloth.isScriptRunning, "the peek is still up")
        }
        stage.dispatch(.mat(command))
        stage.settleMat()
        return ["mat.angle", "mat.size", "mat.folded", "mat.wrinkled", "mat.saved"].map(stage.scene.matExpectation)
    }

    @Test("Rotate, Size or Straighten picked while Peek Under is up lands as it would on a mat at rest, and is saved",
          arguments: transforms)
    func transformDuringPeek(setup: [MatCommand], command: MatCommand) throws {
        let still = try outcome(peek: false, setup: setup, command)
        let peeked = try outcome(peek: true, setup: setup, command)
        #expect(peeked == still, "\(command): \(peeked) vs \(still)")
        #expect(still[2] == "false" && still[4] == "true")
    }

    @Test("A widget nudge at rest moves the keyboard's cover with the keyboard, before any frame")
    func coverFollowsNudge() throws {
        let stage = try PhysicsStage(busyMatDesk([], counts: []), physics: true, mat: true)
        stage.frames(3)
        let se = try #require(stage.scene.matAnchor("mat.corner.se"))
        stage.drag(stage.centre(se), stage.point(core: 220, 204), steps: 40)
        stage.settleMat()
        #expect(!stage.mat.keyboardCover.isHidden, "a fold stands over the keyboard")
        let before = try #require(stage.mat.keyboardRect)
        let screen = try #require(stage.layout.anchors["monitor.screen"])
        stage.scene.avoidRects = [ArtRect(screen.maxX - 1, screen.y, 2, 2)]
        let after = try #require(stage.mat.keyboardRect)
        #expect(after.x != before.x, "the core moved: \(before) → \(after)")
        let expected = SKSpriteNode()
        stage.scene.room!.context.space.place(expected, at: after)
        #expect(!stage.mat.keyboardCover.isHidden && stage.mat.keyboardCover.position == expected.position)
    }

    @Test("A folded mat adopted while the mat is flat lies back at once, and that pose is saved")
    func flatAdoptUnfolds() throws {
        let folding = try PhysicsStage(busyMatDesk([], counts: []), physics: true, mat: true)
        folding.frames(3)
        let se = try #require(folding.scene.matAnchor("mat.corner.se"))
        folding.drag(folding.centre(se), folding.point(core: 334, 186), steps: 40)
        folding.settleMat()
        #expect(folding.scene.matExpectation("mat.folded") == "true" && folding.scene.matExpectation("mat.saved") == "true")
        let folded = folding.state.mat

        // A desk already flat (Settings ▸ Desk mat: Flat, Reduce Motion) that is handed the folded save (a parked
        // folder's layout coming back, `--reduce-motion` at launch).
        let stage = try PhysicsStage(busyMatDesk([], counts: []), physics: true, mat: true)
        stage.scene.matFlat = true
        stage.frames(3)
        stage.state.mat = folded
        stage.scene.apply(stage.state)
        #expect(ClothMetrics.foldedCount(stage.mat.cloth) == 0)
        #expect(stage.state.mat != folded && stage.scene.matExpectation("mat.saved") == "true", "the unfolded pose is saved")
    }

}

@Suite("Release review (scene)")
@MainActor
struct ReleaseReviewCardTests {
    typealias F = SceneFixture

    @Test("A card on show follows the language; a pressed card button is drawn in the card's language")
    func cardLanguage() throws {
        var s = DeskState()
        s.access = .finderHidden
        let scene = F.scene(s)
        let monitor = try #require(scene.monitor)
        let room = try #require(scene.room)
        let font = try #require(room.context.font)
        let wallpaper = MonitorArt.deskOSWallpaper(sky: room.context.sky)
        monitor.language = { .en }
        scene.apply(s)
        #expect(monitor.card == ScreenCard.render(.desktopHidden, wallpaper: wallpaper, font: font, language: .en))
        // Settings ▸ Language applies the same state again.
        monitor.language = { .ko }
        scene.apply(s)
        let ko = try #require(ScreenCard.render(.desktopHidden, wallpaper: wallpaper, font: font, language: .ko))
        #expect(monitor.card == ko)
        for name in ["card.show", "card.keepHidden"] {
            let r = try #require(monitor.cardButtons[name])
            _ = monitor.handle(.press(F.centre(r), []), Hit(element: monitor.id, part: name, rect: r))
            #expect(monitor.pressedNode.texture?.size() == CGSize(width: r.w, height: r.h), "\(name)")
            _ = monitor.handle(.cancelPress, Hit(element: monitor.id, part: name, rect: r))
        }
        #expect(monitor.accessibilityItems().contains { $0.label == "Keep Hidden" }, "VoiceOver stays English (Errata 21)")
    }
}
