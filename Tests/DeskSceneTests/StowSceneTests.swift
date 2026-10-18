import DeskCore
import Foundation
import Metal
import Testing
@testable import DeskScene

/// Put Away and Bring Back in the scene (Erratum 30): dormant slots, the sealed riser, the desk plane, the dust puff.
@Suite("Put away in the scene")
struct StowSceneTests {
    typealias F = SceneFixture
    typealias C = ContainerFixture

    /// The fixture desk with `stowed` put away.
    static func state(_ stowed: Set<StowID>) -> DeskState {
        var s = C.state()
        s.stowed = stowed
        return s
    }

    static let fourAway: Set<StowID> = [.cabinet, .plant, .phoneStand, .partition]

    @Test("Put away, the cabinet, plant, phone stand and partition are dormant: unrouted, their anchors hit the room, no VoiceOver items, hidden, idle")
    func dormant() throws {
        let store = SceneStore(Self.state(Self.fourAway))
        let scene = store.scene
        let p = Pointer(scene: scene)
        C.settle(p)
        let room = try C.room(scene)
        let a = try #require(scene.layout).anchors
        for element in ["cabinet", "plant", "phone", "partition", "partition.clips"] {
            #expect(!scene.isRouted(element), "\(element) is not routed")
        }
        for anchor in ["cabinet", "cabinet.top.handle", "plant", "phone", "partition.post", "partition.cube"] {
            #expect(scene.hitTest(try #require(a.point(anchor)))?.element == "room", "\(anchor) hits the bare room")
        }
        let ids = scene.accessibilityItems().map(\.id)
        #expect(!ids.contains { $0.hasPrefix("cabinet") || $0 == "phone" || $0.hasPrefix("partition") || $0.hasPrefix("note.") })
        let dormant: [any DeskElement] = [
            try #require(room.cabinetElement), try #require(room.phoneElement), try #require(room.partitionElement),
            try #require(room.memoClipsElement), try #require(room.extras.first { $0.id == "plant" }),
        ]
        for e in dormant { #expect(e.root.isHidden, "\(e.id) is hidden") }
        #expect(!room.activeExtras.contains { e in dormant.contains { $0 === e } })
        #expect(!scene.needsFrames)
        // What stays is routed as ever: the riser, the screen, the chair, the hub.
        for element in ["riser", "screen", "monitor", "chair", "hub", "calendar"] { #expect(scene.isRouted(element)) }
    }

    @Test("Piles still hit where they lie; a pile stays a pile on the strip a put-away plant left")
    func pilesUnchanged() throws {
        var s = Self.state([.plant])
        s.tokens.move(F.key(1), to: .desk(pile: "P1", order: 0))
        s.piles["P1"] = [150, 30]
        let store = SceneStore(s)
        let scene = store.scene
        let r = try #require(scene.deskTokenRect(F.key(1)))
        #expect(scene.hitTest(r.center)?.token == F.key(1))
        // The plant's footprint is off the desk plane, so a drop there makes a pile instead of springing back.
        let piles = try #require(try C.room(scene).context.physics?.piles)
        let strip = try #require(scene.layout).point(ArtPoint(48, 172))
        if case .accept(.desk)? = piles.dropVerdict([F.key(2)], at: strip) {} else {
            Issue.record("the plant's strip takes a pile while it is away")
        }
    }

    @Test("Brought back, everything is routed and drawn again and the anchors find their objects")
    func bringBack() throws {
        let store = SceneStore(Self.state(Self.fourAway.union([.riserDrawers])))
        let scene = store.scene
        let room = try C.room(scene)
        var s = store.state
        s.stowed = []
        store.state = s
        scene.apply(s)
        for element in ["cabinet", "plant", "phone", "partition", "riser"] { #expect(scene.isRouted(element)) }
        let a = try #require(scene.layout).anchors
        #expect(scene.hitTest(try #require(a.point("cabinet.top.handle")))?.part == "cabinet.top.handle")
        #expect(scene.hitTest(try #require(a.point("plant")))?.element == "plant")
        #expect(scene.hitTest(try #require(a.point("riser.drawerL.handle")))?.part == "riser.drawerL.handle")
        #expect(scene.hitTest(try #require(a.point("partition.cube")))?.part == "partition.cube")
        #expect(try #require(room.cabinetElement).root.isHidden == false)
        #expect(try #require(room.partitionElement).root.isHidden == false)
        #expect(scene.accessibilityItems().contains { $0.id == "partition.cube" })
    }

    @Test("An object's menu ends with Put Away; the plant's is Put Away Plant, then the desk menu; tokens get none")
    func putAwayMenus() throws {
        let store = SceneStore(C.state([(1, .phone)]))
        let scene = store.scene
        let s = store.state
        let a = try #require(scene.layout).anchors
        let cabinet = scene.contextMenu(at: try #require(a.point("cabinet.top.handle")))
        #expect(cabinet == MenuSpec(MenuSpec.container(.cabinetTop, s).items + MenuSpec.objectPutAway(.cabinet, s)))
        #expect(cabinet.items.last?.id == "putAway")
        let plant = scene.contextMenu(at: try #require(a.point("plant")))
        #expect(plant.items.first?.id == "putAway" && plant.items.dropFirst().first?.isSeparator == true)
        #expect(Array(plant.items.dropFirst(2)) == MenuSpec.desk(s, scene.menuContext).items)
        // A token's menu (a mini on the phone) is the token's, with nothing appended.
        let mini = try #require(scene.miniRect(of: F.key(1)))
        #expect(scene.contextMenu(at: mini.center).item("putAway") == nil)
    }

    @Test("The room state follows the model: what is put away, the clip light, the phone's glow, the memos")
    func roomState() throws {
        var s = Self.state([.phoneStand])
        s.clipLightOn = true
        let today = DayKey(year: 2026, month: 10, day: 14)!
        s.memos.pages[today] = "회의 3시"
        s.memos.pages[DayKey(year: 2026, month: 11, day: 2)!] = "next month"
        s.memos.dDay = DDay(day: DayKey(year: 2026, month: 10, day: 30)!, title: "중간고사")
        let scene = F.scene(s)
        let r = try #require(scene.roomState)
        #expect(r.stowed == [.phoneStand])
        #expect(!r.lights.phoneFaceUp, "the phone's glow goes with the phone stand")
        #expect(r.lights.clipLightOn && r.lights.partitionOut)
        #expect(r.padWritten && r.dDayDays == 16)
        #expect(r.calendarMarks == [14: .memo, 30: .dDay])
        s.stowed = [.partition]
        scene.apply(s)
        let away = try #require(scene.roomState)
        #expect(!away.lights.clipLightOn && !away.lights.partitionOut, "the clip light goes with the partition")
        #expect(away.lights.phoneFaceUp)
    }

    @Test("A dust puff where the object stood (none for wall decor, none with Reduce Motion)")
    func dustPuff() throws {
        let scene = F.scene(Self.state([.cabinet]))
        let room = try C.room(scene)
        scene.play(.putAway, .stowable(.cabinet))
        #expect(room.context.fx.count == 1)
        scene.play(.bringBack, .stowable(.wallShelf))
        #expect(room.context.fx.count == 1, "decor puffs nowhere")
        scene.forceRest()
        scene.reduceMotion = true
        scene.play(.bringBack, .stowable(.plant))
        #expect(room.context.fx.count == 0)
    }

    @Test("The desk plane drops a put-away plant's and phone stand's footprints and takes them back")
    func footprints() throws {
        let store = SceneStore(Self.state([.plant, .phoneStand]))
        let hub = try #require(try C.room(store.scene).context.physics)
        #expect(!hub.world.hasFurniture("plant") && !hub.world.hasFurniture("phone"))
        #expect(hub.world.hasFurniture("lamp") && hub.bodies.stowed == [.plant, .phoneStand])
        var s = store.state
        s.stowed = [.cabinet]
        store.state = s
        store.scene.apply(s)
        #expect(hub.world.hasFurniture("plant") && hub.world.hasFurniture("phone"))
        let avoid = hub.ballistics.floorAvoid
        let span = CoreLayout.cabinet.minX..<CoreLayout.cabinet.maxX
        #expect(!avoid.contains(span), "a put-away cabinet leaves its floor span free")
    }
}

/// The SpriteKit room with everything put away equals its CPU twin (`RoomPlan`), day, night and Lamp Only.
@Suite("Put away in the scene (Metal)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct StowSnapshotTests {
    @Test("SpriteKit + lit pass equal the CPU room plan with everything put away",
          arguments: [(10, LightsMode.auto), (22, .auto), (22, .lampOnly)])
    func matchesCPU(hour: Int, lights: LightsMode) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let host = try SceneHost(grid: PixelGrid(display: calibrationDisplay), device: device)
        let time = WallTime(hour: hour, minute: 0)
        host.scene.clock = .fixed(time)
        host.scene.lightsMode = lights
        let room = try #require(host.scene.room)
        var state = room.state
        state.stowed = Set(StowID.allCases)
        room.setState(state)
        host.scene.connect(presenter: host.presenter)
        let driver = OffscreenDriver(host: host)
        driver.run(frames: 1)
        let lit = try driver.snapshot()
        let layout = try #require(host.scene.layout)
        let shown = try #require(host.scene.roomState)
        #expect(shown.stowed == Set(StowID.allCases))
        let art = try host.presenter.readArtFrame()
        #expect(art == RoomPlan.compose(layout, shown))
        #expect(lit == RoomPlan.render(layout, shown))
    }
}
