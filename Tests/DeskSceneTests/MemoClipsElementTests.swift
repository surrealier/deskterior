import DeskCore
import Foundation
import Testing
@testable import DeskScene

/// The memo clips on the partition (Erratum 31): files clipped up as cards.
@Suite("Memo clips element")
struct MemoClipsElementTests {
    typealias F = SceneFixture
    typealias C = ContainerFixture
    typealias M = MemoFixture

    static func clips(_ scene: DeskScene) throws -> MemoClipsElement {
        try #require(try C.room(scene).memoClipsElement)
    }

    @Test("Clipped files show as cards with their minis, in clip order; their minis are tokens on show")
    func minis() throws {
        let scene = F.scene(M.state(clips: [2, 3]))
        let clips = try Self.clips(scene)
        let layout = try #require(scene.layout)
        #expect(clips.cards.map(\.key) == [F.key(2), F.key(3)])
        #expect(clips.cards.map(\.rect) == [0, 1].map { layout.rect(CoreLayout.memoClipCard($0)) })
        #expect(scene.miniRect(of: F.key(3)) == layout.rect(CoreLayout.memoClipCard(1)))
        #expect(scene.containerMinis == [F.key(2), F.key(3)])
        #expect(clips.hitTest(layout.rect(CoreLayout.memoClipCard(0)).center)?.token == F.key(2))
        #expect(clips.hitTest(layout.rect(CoreLayout.memoClipCard(3)).center)?.part == "partition.clips")
        let image = try #require(clips.drawnImage)
        #expect(image.size == CoreLayout.partitionClips.size)
        #expect(image.pixels.allSatisfy { $0.a == 0 || ($0.a == 255 && Apollo.index(of: $0) != nil) })
        // Put away, none show.
        scene.apply(M.state(stowed: [.memoClips]))
        #expect(clips.cards.isEmpty && clips.hitTest(layout.rect(CoreLayout.memoClipCard(0)).center) == nil)
        #expect(clips.accessibilityItems().isEmpty)
    }

    @Test("Hovering a card names its file; the wire says what the clips hold")
    func hoverName() throws {
        let scene = F.scene(M.state(clips: [2]))
        let clips = try Self.clips(scene)
        let card = try #require(clips.cards.first)
        let hit = try #require(clips.hitTest(card.rect.center))
        #expect(clips.tooltip(hit)?.title == F.names[1])
        let wire = Hit(element: clips.id, part: "partition.clips", rect: clips.railRect)
        #expect(clips.tooltip(wire)?.title == "Memo Clips" && clips.tooltip(wire)?.detail == "1 item")
        #expect(clips.accessibilityItems().map(\.label) == ["Memo clips, 1 files", F.names[1]])
    }

    @Test("Through the pointer: hover names a card, a double-click opens it, a drag takes it back to the monitor")
    func pointer() throws {
        let store = SceneStore(M.state(clips: [2, 3]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let card = try #require(scene.miniRect(of: F.key(2)))
        #expect(scene.hitTest(card.center)?.token == F.key(2) && scene.hitTest(card.center)?.element == "partition.clips")
        p.click(F.centre(card), count: 2)
        #expect(store.opens == ["requestOpen([\(F.key(2))])"])
        let screen = try #require(scene.screen)
        p.drag(F.centre(card), F.centre(screen.cellRect(8, 4)))
        #expect(store.actions.last == "move([\(F.key(2))], to: screen p0(8,4))")
    }

    @Test("A double-click on a card opens it (the element straight)")
    func doubleClick() throws {
        let store = SceneStore(M.state(clips: [2]))
        let clips = try Self.clips(store.scene)
        let card = try #require(clips.cards.first)
        let hit = try #require(clips.hitTest(card.rect.center))
        _ = clips.handle(.press(F.centre(card.rect), []), hit)
        _ = clips.handle(.click(F.centre(card.rect), [], count: 2), hit)
        #expect(store.opens == ["requestOpen([\(F.key(2))])"])
    }

    @Test("Drops on the wire clip up while there is room; full, they bonk (The memo clips are full.)")
    func bonkWhenFull() throws {
        let scene = F.scene(M.state(clips: [1, 2, 3, 4]))
        let clips = try Self.clips(scene)
        let wire = clips.railRect.center
        #expect(clips.dropVerdict([F.key(9)], at: wire) == .accept(.container(.memoClips, order: 4)))
        #expect(clips.dropVerdict([F.key(9), F.key(10)], at: wire) == .bonk(.memoClipsFull))
        #expect(clips.dropVerdict([F.key(1), F.key(9)], at: wire) == .accept(.container(.memoClips, order: 4)))
        let store = SceneStore(M.state(clips: [1, 2, 3, 4, 5]))
        let p = Pointer(scene: store.scene)
        let screen = try #require(store.scene.screen)
        p.drag(F.centre(try #require(screen.iconRect(of: F.key(6)))), F.centre(try Self.clips(store.scene).railRect))
        #expect(store.scene.bonkCount == 1 && store.scene.toastShown == .memoClipsFull)
        // With room, a carry over the felt rings the next free clip.
        let open = SceneStore(M.state(clips: [1]))
        let q = Pointer(scene: open.scene)
        let openClips = try Self.clips(open.scene)
        let plain = try #require(openClips.drawnImage)
        let icon = try #require(open.scene.screen?.iconRect(of: F.key(6)))
        q.drag(F.centre(icon), M.point(open.scene, core: 480, 150), hold: true)
        #expect(try #require(openClips.drawnImage) != plain)
        _ = q.event(.up, M.point(open.scene, core: 480, 150), count: 1)
        #expect(open.actions.last == "move([\(F.key(6))], to: memoClips#1)")
        #expect(store.state.tokens.location(of: F.key(6))?.isScreen == true)
    }

    @Test("The menu is the container menu with Put Away Memo Clips; Show on Desk selects a clipped file")
    func menuAndPulse() throws {
        let store = SceneStore(M.state(clips: [2]))
        let scene = store.scene
        let p = Pointer(scene: scene)
        let clips = try Self.clips(scene)
        let wire = Hit(element: clips.id, part: "partition.clips", rect: clips.railRect)
        let s = store.state
        #expect(clips.menu(wire) == MenuSpec(MenuSpec.container(.memoClips, s).items + MenuSpec.memoClipsExtras(s)))
        #expect(clips.menu(wire)?.item("takeAllOut") != nil)
        scene.play(.pulse, .token(F.key(2)))
        p.frames(1)
        #expect(scene.selection?.keys == [F.key(2)])
    }
}
