import DeskCore
import DeskPixels
import Foundation
import Testing
@testable import DeskScene

/// The wave-6 polish after its visual review, in the scene (Errata 26).
@Suite("Scene polish review (wave 6)")
struct PolishReviewSceneTests {
    typealias F = SceneFixture

    @Test("Wall decor is part of the backdrop: no ring over the tall wall's shelf, prints or ceiling lamp")
    func decorIsInert() throws {
        for id in ["decor.upperShelf.12", "decor.gallery.13", "decor.ceilingLamp.11", "decor.painting.3"] {
            #expect(RoomContent.elementID(for: id) == "room", "\(id)")
        }
        let portrait = DisplayGeometry(widthPt: 1080, heightPt: 1920, backingScale: 1, topInsetPt: 25)
        let scene = DeskScene(grid: PixelGrid(display: portrait))
        scene.clock = .fixed(WallTime(hour: 10, minute: 0))
        scene.apply(F.state())
        let room = try #require(scene.room)
        let p = Pointer(scene: scene)
        for kind in [WallDecor.Kind.upperShelf, .gallery, .ceilingLamp] {
            let r = try #require(room.layout.decor(kind).first).rect
            // A drawn pixel of the piece.
            let sprite: PixelBuffer = DecorArt.sprite(WallDecor(kind, r)).image
            let cells: [Int] = Array(0..<(r.w * r.h))
            let at: Int = try #require(cells.first { (i: Int) -> Bool in sprite[i % r.w, i / r.w].a != 0 })
            let point: SIMD2<Float> = F.centre(ArtRect(r.x + at % r.w, r.y + at / r.w, 1, 1))
            _ = p.event(.move, point)
            #expect((scene.hoveredHit?.element ?? "room") == "room" && room.hoverRing == nil, "\(kind)")
        }
    }

    @Test("The NO SIGNAL card's badge is in the card's language; English keeps the monitor's own logo")
    func noSignalBadge() throws {
        let font = try #require(PixelFont.galmuri9)
        #expect(ScreenCard.noSignalBadge(font, .en) == MonitorArt.noSignalLogo().image)
        let ko = ScreenCard.noSignalBadge(font, .ko)
        #expect(ko != MonitorArt.noSignalLogo().image && ko.width < CoreLayout.screen.w - 20)
        #expect(L10n.tr("NO SIGNAL", .ko) == "신호 없음")
    }

    @Test("A card's panel never leaves a sliver of the night wallpaper's moon over its top edge")
    func cardsClearTheMoon() {
        let night = MonitorArt.deskOSWallpaper(sky: .night), day = MonitorArt.deskOSWallpaper(sky: .day)
        let moon = MonitorArt.nightMoon(in: night.size)
        for top in (moon.minY + 1)..<moon.maxY {
            let panel = ArtRect(10, top, night.width - 20, 70)
            let moved = ScreenCard.clearOfMoon(panel, on: night)
            #expect(moved.minY >= moon.maxY || moved.minY < moon.minY, "top \(top) → \(moved.minY)")
            #expect(moved.maxY <= night.height && moved.size == panel.size)
            #expect(ScreenCard.clearOfMoon(panel, on: day) == panel)
        }
    }
}

// MARK: Peek Under beside the keyboard

extension PolishReviewSceneTests {
    @Test("A tongue Peek Under turns up before the keyboard, and the card it reveals, are drawn over the keyboard")
    func peekCoversTheKeyboard() throws {
        let flat = try PhysicsStage(matDesk([]), physics: true, mat: true)
        flat.settleMat()
        #expect(flat.mat.keyboardCover.isHidden, "flat felt never covers the keyboard")
        let stage = try PhysicsStage(matDesk([[292, 30]], counts: [2]), physics: true, mat: true)
        stage.frames(3)
        #expect(stage.mat.coversPile("P1"))
        stage.mat.lastHitPoint = stage.point(plane: [292, 14])
        stage.dispatch(.mat(.peekUnder))
        stage.frames(24)
        #expect(!stage.mat.coversPile("P1"))
        #expect(!stage.mat.keyboardCover.isHidden, "the lifted cloth stands in front of the keyboard")
        let kb = try #require(stage.mat.keyboardRect)
        #expect(stage.mat.keyboardCover.zPosition > stage.scene.room!.context.placementZ("keyboard"))
        #expect(stage.mat.keyboardCover.texture?.size() == CGSize(width: kb.w, height: kb.h))
    }
}
