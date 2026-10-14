import DeskCore
import Testing
@testable import DeskScene

/// The drive hub (E15) and the scene's side of drag-out and drop-in (M11).
@Suite("Drive hub and file drops in the scene")
struct DriveHubElementTests {
    typealias F = SceneFixture

    static func volumes(_ n: Int) -> [VolumeEntry] {
        let kinds: [VolumeEntry.Kind] = [.removable, .externalDisk, .server, .internalDisk, .externalDisk]
        return (0..<n).map {
            VolumeEntry(id: "V\($0)", name: "Drive \($0)", path: "/Volumes/Drive \($0)", kind: kinds[$0 % kinds.count],
                        isEjectable: $0 != 3)
        }
    }

    static func store(volumes n: Int) -> SceneStore {
        var s = F.state()
        s.volumes = volumes(n)
        return SceneStore(s)
    }

    @Test("Up to four drives stand in the hub's ports; the rest sit behind a \"+n\" tag beside it")
    func drives() throws {
        let store = Self.store(volumes: 5)
        let scene = store.scene
        #expect(scene.hubDrives.shown == 4 && scene.hubDrives.more == 1)
        let hub = try #require(scene.layout).rect(CoreLayout.driveHub)
        var lastX = Int.min
        for i in 0..<4 {
            let r = try #require(scene.fileAnchor("hub.drive.\(i)"))
            #expect(r.maxY > hub.minY && r.minY < hub.minY, "drive \(i) stands in the hub")
            #expect(r.minX > lastX)
            lastX = r.minX
            let hit = try #require(scene.hitTest(ArtPoint(r.midX, r.midY)))
            #expect(hit.element == "hub" && hit.part == "hub.drive.\(i)")
        }
        let more = try #require(scene.fileAnchor("hub.more"))
        #expect(more.minX >= hub.maxX && scene.hitTest(ArtPoint(more.midX, more.midY))?.part == "hub.more")
        #expect(scene.fileAnchor("hub.drive.4") == nil)
        // Fewer volumes: no tag; none: just the hub.
        var s = store.state
        s.volumes = Self.volumes(2)
        store.dispatch(.volumes(s.volumes))
        #expect(scene.hubDrives.shown == 2 && scene.hubDrives.more == 0 && scene.fileAnchor("hub.more") == nil)
        store.dispatch(.volumes([]))
        #expect(scene.hubDrives.shown == 0 && scene.hitTest(ArtPoint(hub.midX, hub.midY))?.element == "hub")
    }

    @Test("Hover names a drive; a double-click opens it; its menu offers Open, Show in Finder, Eject")
    func gestures() throws {
        let store = Self.store(volumes: 5)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let r1 = try #require(scene.fileAnchor("hub.drive.1"))
        p.event(.move, F.centre(r1))
        p.frames(20)
        #expect(scene.tooltipShown?.title == "Drive 1" && scene.tooltipShown?.detail == "External disk")
        p.click(F.centre(r1), count: 2)
        #expect(store.actions.contains { $0.contains("requestOpenVolume(\"V1\")") })
        let menu = scene.contextMenu(at: ArtPoint(r1.midX, r1.midY))
        #expect(menu.ids == ["drive.open", "drive.reveal", "drive.eject"] && menu.item("drive.eject")?.isEnabled == true)
        let r3 = try #require(scene.fileAnchor("hub.drive.3"))
        #expect(scene.contextMenu(at: ArtPoint(r3.midX, r3.midY)).item("drive.eject")?.isEnabled == false,
                "a volume that cannot be ejected")
        // The "+1" tag lists the others, on a click and on its menu.
        let more = try #require(scene.fileAnchor("hub.more"))
        p.click(F.centre(more))
        guard case let .menu(spec, _)? = store.requests.last else {
            Issue.record("the tag's click shows a menu")
            return
        }
        #expect(spec.ids == ["drive.4", "drive.4.open", "drive.4.reveal", "drive.4.eject"])
        #expect(scene.contextMenu(at: ArtPoint(more.midX, more.midY)) == spec)
        let items = scene.accessibilityItems().filter { $0.id.hasPrefix("drive.") }
        #expect(items.map(\.label) == ["Drive Drive 0", "Drive Drive 1", "Drive Drive 2", "Drive Drive 3", "1 more drives"])
    }

    @Test("Tokens and files dropped on the hub or a drive bonk: copying to drives is Finder's job")
    func drivesBonk() throws {
        let store = Self.store(volumes: 2)
        let scene = store.scene
        let p = Pointer(scene: scene)
        let drive = try #require(scene.fileAnchor("hub.drive.0"))
        #expect(scene.fileDropVerdict(count: 1, at: F.centre(drive)) == .bonk(.drivesReadOnly))
        let icon = try #require(scene.screen?.iconRect(of: F.key(1)))
        p.drag(F.centre(icon), F.centre(drive))
        p.frames(10)
        #expect(scene.bonkCount == 1 && scene.toastShown == .drivesReadOnly)
        #expect(store.state.tokens.location(of: F.key(1)) == .screen(page: 0, col: 0, row: 0))
    }

    @Test("Files dropped from outside land where a carry would: a cell, a drawer, a new pile at the spot, the floor")
    func fileDropVerdicts() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let layout = try #require(scene.layout)
        func at(core x: Int, _ y: Int) -> SIMD2<Float> {
            let q = layout.point(ArtPoint(x, y))
            return SIMD2(Float(q.x) + 0.5, Float(q.y) + 0.5)
        }
        let cell = try #require(scene.screen?.cellRect(8, 4))
        #expect(scene.fileDropVerdict(count: 2, at: F.centre(cell)) == .land(.screen(page: 0, col: 8, row: 4), pilePos: nil))
        let drawer = try #require(scene.liveAnchor("riser.drawerL.front") ?? layout.anchors["riser.drawerL.front"])
        #expect(scene.fileDropVerdict(count: 1, at: F.centre(drawer)) == .land(.container(.riserLeft, order: 0), pilePos: nil))
        guard case let .land(.desk(pile, 0), pos?) = scene.fileDropVerdict(count: 1, at: at(core: 96, 206)) else {
            Issue.record("a drop on the bare desk starts a pile there")
            return
        }
        #expect(pile == store.state.makePileID() && pos.x > 60 && pos.x < 130)
        guard case .land(.floor, nil) = scene.fileDropVerdict(count: 1, at: at(core: 120, CoreLayout.floorY - 4)) else {
            Issue.record("a drop on the floor lands on the floor")
            return
        }
        // While the screen is off it refuses, as for tokens.
        store.dispatch(.power(false))
        #expect(scene.fileDropVerdict(count: 1, at: F.centre(cell)) == .bonk(nil))
        scene.bonkFileDrop(at: F.centre(cell), nil)
        #expect(scene.bonkCount == 1)
    }

    @Test("A carry leaving the window is handed off: the stack goes, the tokens are home; a drag-out's wait hides them")
    func handOff() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let icon = try #require(screen.iconRect(of: F.key(2)))
        p.drag(F.centre(icon), F.centre(icon) + SIMD2(30, 40), hold: true)
        #expect(scene.carriedTokenKeys == [F.key(2)] && scene.isDragging)
        #expect(scene.handOffCarry() == [F.key(2)])
        #expect(!scene.isDragging && scene.carriedTokenKeys == nil && screen.carried.isEmpty)
        #expect(store.state.tokens.location(of: F.key(2)) == .screen(page: 0, col: 1, row: 0), "nothing moved")
        #expect(scene.handOffCarry() == nil)
        // The mouse-up AppKit swallowed changes nothing either.
        p.event(.up, F.centre(icon) + SIMD2(30, 40), count: 1)
        #expect(store.state.tokens.location(of: F.key(2)) == .screen(page: 0, col: 1, row: 0))
        scene.holdForDragOut([F.key(2)])
        #expect(screen.carried == [F.key(2)], "not drawn while its file may be leaving")
        scene.revealDragOut([F.key(2)])
        #expect(screen.carried.isEmpty)
        #expect(scene.dragImage(for: [F.key(2)])?.size == ArtSize(16, 16))
    }

    @Test("A ball leaving the wastebasket for the trash puffs at its mouth")
    func basketPuff() {
        let scene = SceneStore(F.state()).scene
        #expect(!scene.needsFrames)
        scene.play(.handleWiggle, .container(.wastebasket))
        #expect(scene.needsFrames)
    }
}
