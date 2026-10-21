import DeskCore
import Foundation
import Metal
import Testing
@testable import DeskScene

/// The picture frame in the scene (Erratum 33): the framed print over the wall shelf is an element of its own, rings,
/// names itself (never a file), asks for a photo, hangs a carried picture without moving it, and goes dormant with the
/// wall shelf. `IMG_0001.png` is key 2, `notes.md` key 3.
@Suite("Picture frame element")
struct FrameElementTests {
    typealias F = SceneFixture
    typealias C = ContainerFixture

    static let sample = FramePhoto.sample

    /// The frame's canvas rect in `scene` (required: it hangs on this Mac's default display).
    static func frameRect(_ scene: DeskScene) throws -> ArtRect { try #require(scene.pictureFrameRect) }

    static func frame(_ scene: DeskScene) throws -> FrameElement { try #require(try C.room(scene).frameElement) }

    /// The room's placed print (its `decor.frame.*` sprite).
    static func placed(_ scene: DeskScene) throws -> PlacedElement {
        try #require(try C.room(scene).elements.first { $0.id == "frame" })
    }

    /// The frame's AX item, if offered.
    static func axItem(_ scene: DeskScene) -> AXItem? { scene.accessibilityItems().first { $0.id == "frame" } }

    /// Runs `body` with the scene's words in Korean, then restores the language (the suite runs on the main actor and
    /// `body` never suspends, so no other test sees Korean).
    static func inKorean<T>(_ body: () throws -> T) rethrows -> T {
        let saved = L10n.language
        L10n.language = .ko
        defer { L10n.language = saved }
        return try body()
    }

    /// The token's icon centre on the screen.
    static func icon(_ scene: DeskScene, _ i: UInt64) throws -> SIMD2<Float> {
        let screen = try #require(scene.screen)
        return F.centre(try #require(screen.iconRect(of: F.key(i))))
    }

    @Test("decor.frame.* is the frame element, whatever its index; every other decor stays the room's")
    func elementIDs() {
        #expect(RoomContent.elementID(for: "decor.frame.4") == "frame")
        #expect(RoomContent.elementID(for: "decor.frame.0") == "frame")
        for id in ["decor.painting.3", "decor.shelf.2", "decor.stringLights.0"] {
            #expect(RoomContent.elementID(for: id) == "room", "\(id)")
        }
        #expect(RoomContent.anchorPrefixes(for: "frame") == ["frame"])
    }

    @Test("Hover rings the frame; its tooltip and VoiceOver say Picture Frame (in Korean too), valued No photo / Your photo")
    func hoverTooltipAX() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let room = try C.room(scene)
        let r = try Self.frameRect(scene)
        #expect(r.size == ArtSize(32, 40))
        #expect(scene.hitTest(r.center)?.element == "frame")
        #expect(scene.hitTest(r.center)?.part == nil && scene.hitTest(r.center)?.rect == r)
        _ = p.event(.move, F.centre(r))
        #expect(scene.hoveredHit?.element == "frame")
        #expect(room.hoverRing != nil, "the frame is ringed")
        p.frames(20)
        #expect(scene.tooltipShown?.title == "Picture Frame")
        #expect(scene.tooltipShown?.detail == "Click to choose a photo · drop one on it")

        let empty = try #require(Self.axItem(scene))
        #expect(empty.label == "Picture Frame" && empty.value == "No photo" && empty.role == .button)
        #expect(empty.frame == r && empty.token == nil)
        // Every other item has no value (the field is new).
        #expect(scene.accessibilityItems().filter { $0.id != "frame" }.allSatisfy { $0.value == nil })

        let frame = try Self.frame(scene)
        let hit = Hit(element: "frame", part: nil, rect: r)
        try Self.inKorean {
            #expect(frame.tooltip(hit)?.title == "사진 액자")
            #expect(frame.tooltip(hit)?.detail == L10nKey.pictureFrameHelp.ko)
            let item = try #require(Self.axItem(scene))
            #expect(item.label == "사진 액자" && item.value == "사진 없음")
        }
        #expect(frame.tooltip(hit)?.title == "Picture Frame", "the language is restored")

        store.dispatch(.hangPhoto(Self.sample))
        // The tooltip on show follows the model: hung, no help line (and never a file name).
        #expect(scene.tooltipShown?.title == "Picture Frame" && scene.tooltipShown?.detail == nil)
        #expect(frame.tooltip(hit)?.detail == nil)
        let hung = try #require(Self.axItem(scene))
        #expect(hung.label == "Picture Frame" && hung.value == "Your photo" && hung.role == .button)
        #expect(hung != empty, "a changed value rebuilds the app's element")
        #expect(Self.inKorean { Self.axItem(scene)?.value } == "내 사진")
    }

    @Test("Right-click: Choose Photo…, Remove Photo while one hangs, then Put Away Wall Shelf")
    func menu() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let r = try Self.frameRect(scene)
        let empty = scene.contextMenu(at: r.center)
        #expect(empty.ids == ["choosePhoto", "putAway"])
        #expect(empty.item("choosePhoto")?.content == .command(.choosePhoto))
        let putAway = try #require(empty.item("putAway"))
        #expect(putAway.title == "Put Away Wall Shelf" && putAway.content == .command(.putAway(.wallShelf)))
        store.dispatch(.hangPhoto(Self.sample))
        let hung = scene.contextMenu(at: r.center)
        #expect(hung.ids == ["choosePhoto", "removePhoto", "putAway"])
        #expect(hung.item("removePhoto")?.content == .command(.removePhoto))
        #expect(hung.item("putAway")?.title == "Put Away Wall Shelf")
        // The scene's menu is the element's own plus the room's Put Away.
        let frame = try Self.frame(scene)
        #expect(frame.menu(Hit(element: "frame", part: nil, rect: r)) == MenuSpec.frame(store.state))
    }

    @Test("A click on the empty frame asks for a photo; hung, a click is the bare wall's (it clears the selection)")
    func click() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let c = F.centre(try Self.frameRect(scene))
        p.click(c)
        #expect(store.requests.last == .command(.choosePhoto))
        #expect(store.actions.isEmpty, "a click changes nothing in the model")
        let asked = store.requests.count
        // A double-click's second click asks no second time.
        p.click(c, count: 2)
        #expect(store.requests.count == asked + 1)

        store.dispatch(.hangPhoto(Self.sample))
        p.click(try Self.icon(scene, 1))
        #expect(scene.selection?.keys == [F.key(1)])
        let before = store.requests.count
        p.click(c)
        #expect(store.requests.count == before, "no new request")
        #expect(scene.selection?.isEmpty == true, "the selection is cleared")
    }

    @Test("A carried picture asks the app to hang it and springs back; others bonk with why")
    func carry() throws {
        var s = F.state()
        // Key 10 is the screenshot; make key 11 (todo.txt) an iCloud placeholder picture.
        var cloud = try #require(s.tokens.meta(of: F.key(11)))
        cloud.name = "beach.png"
        cloud.kind = .image
        cloud.isDataless = true
        s.tokens.updateMeta(F.key(11), cloud)
        let store = SceneStore(s)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let c = F.centre(try Self.frameRect(scene))
        let home = store.state.tokens.location(of: F.key(2))

        p.drag(try Self.icon(scene, 2), c)
        #expect(store.requests.last == .command(.hangInFrame(F.key(2))))
        #expect(store.actions.isEmpty, "no action: the app reads the photo, the token stays put")
        #expect(scene.bonkCount == 0 && scene.toastShown == nil)
        #expect(screen.carried == [F.key(2)], "it springs back")
        p.frames(8)
        #expect(screen.carried.isEmpty)
        #expect(store.state.tokens.location(of: F.key(2)) == home, "its cell exactly as before")

        // A text file bonks: not a photo, no request.
        let asked = store.requests.count
        p.drag(try Self.icon(scene, 3), c)
        p.frames(8)
        #expect(scene.toastShown == .notAPhoto && scene.bonkCount == 1)
        #expect(store.requests.count == asked && store.actions.isEmpty)

        // Two selected: one photo at a time.
        p.click(try Self.icon(scene, 2))
        p.click(try Self.icon(scene, 3), mods: .command)
        #expect(scene.selection?.keys == [F.key(2), F.key(3)])
        p.drag(try Self.icon(scene, 2), c)
        p.frames(8)
        #expect(scene.toastShown == .onePhotoAtATime && scene.bonkCount == 2)
        #expect(store.requests.count == asked && store.actions.isEmpty)

        // An iCloud placeholder would download if read: it bonks. (Esc first: a selected name's label covers the cell
        // below it.)
        #expect(scene.handleKey(.escape))
        p.click(try Self.icon(scene, 11))
        #expect(scene.selection?.keys == [F.key(11)])
        p.drag(try Self.icon(scene, 11), c)
        p.frames(8)
        #expect(scene.toastShown == .photoInCloud && scene.bonkCount == 3)
        #expect(store.requests.count == asked && store.actions.isEmpty)

        // The screenshot hangs too.
        scene.handleKey(.escape)
        p.click(try Self.icon(scene, 10))
        #expect(scene.selection?.keys == [F.key(10)])
        p.drag(try Self.icon(scene, 10), c)
        #expect(store.requests.last == .command(.hangInFrame(F.key(10))))
        p.frames(8)

        // A fling released over the frame hangs too and never flies (`PhysicsHub.release` leaves it to the carry).
        let requests = store.requests.count
        p.drag(try Self.icon(scene, 2), c, steps: 2)
        #expect(store.requests.count == requests + 1 && store.requests.last == .command(.hangInFrame(F.key(2))))
        C.settle(p)
        #expect(store.state.tokens.location(of: F.key(2)) == home && store.actions.isEmpty)

        // With Reduce Motion the spring-back ends at once.
        scene.reduceMotion = true
        scene.handleKey(.escape)
        p.click(try Self.icon(scene, 2))
        p.drag(try Self.icon(scene, 2), c)
        #expect(store.requests.last == .command(.hangInFrame(F.key(2))))
        #expect(screen.carried.isEmpty && !scene.isDragging)
        #expect(store.state.tokens.location(of: F.key(2)) == home && store.actions.isEmpty)
    }

    @Test("The element straight: a verdict only over the print, from the tokens the model knows")
    func verdictsStraight() throws {
        let scene = F.scene()
        let frame = try Self.frame(scene)
        let r = try Self.frameRect(scene)
        #expect(frame.dropVerdict([F.key(2)], at: r.center) == .hang(F.key(2)))
        #expect(frame.dropVerdict([F.key(3)], at: r.center) == .bonk(.notAPhoto))
        #expect(frame.dropVerdict([F.key(2), F.key(10)], at: r.center) == .bonk(.onePhotoAtATime))
        #expect(frame.dropVerdict([TokenKey(volume: "drop-in", inode: 1)], at: r.center) == .bonk(.notAPhoto))
        #expect(frame.dropVerdict([F.key(2)], at: ArtPoint(r.minX - 1, r.midY)) == nil)
        // Without a model the frame is inert.
        let bareScene = F.scene(nil)
        let bare = try Self.frame(bareScene)
        let bareHit = Hit(element: "frame", part: nil, rect: try Self.frameRect(bareScene))
        #expect(bare.dropVerdict([F.key(2)], at: bareHit.rect.center) == nil && bare.accessibilityItems().isEmpty)
        #expect(bare.menu(bareHit) == nil)
        let passes = if case .pass = bare.handle(.click(.zero, [], count: 1), bareHit) { true } else { false }
        #expect(passes, "a bare frame passes clicks")
    }

    @Test("Files dropped from outside never land over the frame: one bonks as not a photo, two as one at a time")
    func fileDropSafetyNet() throws {
        let scene = F.scene()
        let c = F.centre(try Self.frameRect(scene))
        #expect(scene.fileDropVerdict(count: 1, at: c) == .bonk(.notAPhoto))
        #expect(scene.fileDropVerdict(count: 2, at: c) == .bonk(.onePhotoAtATime))
    }

    @Test("isOverPictureFrame: the print's pixels, not beside it, not the bare wall")
    func isOver() throws {
        let scene = F.scene()
        let r = try Self.frameRect(scene)
        #expect(scene.isOverPictureFrame(F.centre(r)))
        #expect(scene.isOverPictureFrame(SIMD2(Float(r.minX) + 0.5, Float(r.minY) + 0.5)), "its corner")
        #expect(!scene.isOverPictureFrame(SIMD2(Float(r.minX - 1) + 0.5, Float(r.midY) + 0.5)), "one px left")
        let wall = try #require(scene.layout).point(ArtPoint(260, 4))
        #expect(scene.hitTest(wall)?.element == "room", "core 260,4 is bare wall")
        #expect(!scene.isOverPictureFrame(SIMD2(Float(wall.x) + 0.5, Float(wall.y) + 0.5)))
    }

    @Test("A photo hung or taken down redraws the frame's placement in place; the room state carries it")
    func photoRefresh() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let room = try C.room(scene)
        let r = try Self.frameRect(scene)
        let placed = try Self.placed(scene)
        let print = DecorArt.frame(r.size).image
        let photo = DecorArt.frame(r.size, photo: Self.sample.image).image
        #expect(print != photo)
        #expect(placed.placements.map(\.image) == [print])
        #expect(placed.placements.first?.id.hasPrefix("decor.frame.") == true)
        #expect(scene.roomState?.framePhoto == nil)
        let routedBefore = room.routing.map { ObjectIdentifier($0) }

        store.dispatch(.hangPhoto(Self.sample))
        #expect(try Self.placed(scene) === placed, "refreshed in place, not rebuilt")
        #expect(placed.placements.map(\.image) == [photo])
        #expect(placed.placements.first?.sprite.name == "decor.frame.photo")
        #expect(scene.roomState?.framePhoto == Self.sample.image)
        #expect(room.routing.map { ObjectIdentifier($0) } == routedBefore)
        // The rest of the decor is untouched.
        let others = try #require(room.elements.first { $0.id == "room" }).placements.filter { $0.id.hasPrefix("decor.") }
        #expect(!others.isEmpty && !others.contains { $0.id.hasPrefix("decor.frame.") })

        store.dispatch(.removePhoto)
        #expect(try Self.placed(scene) === placed)
        #expect(placed.placements.map(\.image) == [print])
        #expect(scene.roomState?.framePhoto == nil)

        // A regrid keeps the photo (`buildContent` goes through `roomState(for:)`).
        store.dispatch(.hangPhoto(Self.sample))
        scene.configure(grid: PixelGrid(display: DisplayGeometry(widthPt: 1920, heightPt: 1080, backingScale: 1,
                                                                   topInsetPt: 25)))
        #expect(scene.roomState?.framePhoto == Self.sample.image)
        let wide = try Self.placed(scene)
        #expect(wide !== placed && wide.placements.map(\.image) == [DecorArt.frame(ArtSize(32, 40), photo: Self.sample.image).image])
    }

    @Test("Put away with the wall shelf the frame is dormant; brought back it is routed again, the photo still in it")
    func putAway() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let r = try Self.frameRect(scene)
        let frame = try Self.frame(scene)
        store.dispatch(.hangPhoto(Self.sample))
        store.dispatch(.putAway(.wallShelf))
        C.settle(p)
        #expect(!scene.isRouted("frame"))
        #expect(scene.hitTest(r.center)?.element == "room", "the frame's place is bare wall")
        #expect(Self.axItem(scene) == nil)
        #expect(scene.pictureFrameRect == nil && !scene.isOverPictureFrame(F.centre(r)))
        #expect(frame.root.isHidden)
        #expect(try C.room(scene).elements.first { $0.id == "frame" } == nil)
        #expect(scene.contextMenu(at: r.center).item("choosePhoto") == nil)

        store.dispatch(.bringBack(.wallShelf))
        C.settle(p)
        #expect(scene.isRouted("frame") && scene.pictureFrameRect == r)
        #expect(scene.hitTest(r.center)?.element == "frame" && !frame.root.isHidden)
        #expect(try Self.placed(scene).placements.map(\.image) == [DecorArt.frame(r.size, photo: Self.sample.image).image])
        #expect(Self.axItem(scene)?.value == "Your photo")
    }
}

/// The SpriteKit room with a photo in the frame equals its CPU twin (`RoomPlan`), day, night and Lamp Only. No
/// `DeskState` is applied: a state's tokens would put screen sprites in the GPU frame that `RoomPlan.compose` never
/// draws; the photo goes straight into the room's state.
@Suite("Picture frame in the scene (Metal)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct FrameSnapshotTests {
    @Test("SpriteKit + lit pass equal the CPU room plan with a photo hung",
          arguments: [(10, LightsMode.auto), (22, .auto), (22, .lampOnly)])
    func matchesCPUWithPhoto(hour: Int, lights: LightsMode) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let host = try SceneHost(grid: PixelGrid(display: calibrationDisplay), device: device)
        host.scene.clock = .fixed(WallTime(hour: hour, minute: 0))
        host.scene.lightsMode = lights
        let room = try #require(host.scene.room)
        var st = room.state
        st.framePhoto = FramePhoto.sample.image
        room.setState(st)
        host.scene.connect(presenter: host.presenter)
        let driver = OffscreenDriver(host: host)
        driver.run(frames: 1)
        let lit = try driver.snapshot()
        let layout = try #require(host.scene.layout)
        let shown = try #require(host.scene.roomState)
        #expect(shown.framePhoto == FramePhoto.sample.image, "with no model, the room keeps the state it was given")
        let art = try host.presenter.readArtFrame()
        let cpuArt = RoomPlan.compose(layout, shown)
        #expect(art == cpuArt, "\(diffCount(art, cpuArt)) unlit px differ")
        let cpuLit = RoomPlan.render(layout, shown)
        #expect(lit == cpuLit, "\(diffCount(lit, cpuLit)) lit px differ")
        #expect(lit.pixels.allSatisfy { Apollo.index(of: $0) != nil })
        // The frame's window holds the photo's pixels.
        let frame = try #require(layout.decor(.frame).first).rect
        let window = DecorArt.photoWindow(in: frame.size).offsetBy(frame.x, frame.y)
        #expect(window.size == FramePhoto.size)
        var differ = 0
        for y in 0..<window.h {
            for x in 0..<window.w where art[window.x + x, window.y + y] != FramePhoto.sample.image[x, y] { differ += 1 }
        }
        #expect(differ == 0, "\(differ) px of the photo differ")
    }
}
