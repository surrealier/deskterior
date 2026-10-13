import DeskCore
import Metal
import Testing
@testable import DeskScene

/// The room at fixed times on this Mac's default display.
@MainActor
private func roomScene(_ time: WallTime, lights: LightsMode = .auto) -> DeskScene {
    let scene = DeskScene(grid: PixelGrid(display: calibrationDisplay))
    scene.clock = .fixed(time)
    scene.lightsMode = lights
    return scene
}

@Suite("Room scene (CPU)")
struct RoomSceneTests {
    @Test("The room is the default content; calibration is one call away")
    func contentSwitch() {
        let scene = DeskScene(grid: PixelGrid(display: calibrationDisplay))
        #expect(scene.content == .room && scene.room != nil && scene.calibration == nil)
        scene.setContent(.calibration)
        #expect(scene.calibration != nil && scene.room == nil && scene.layout == nil)
        #expect(scene.lighting.ambient == .identity && scene.lighting.mask.allSatisfy { $0 == 0 })
        scene.setContent(.room)
        #expect(scene.room != nil)
    }

    @Test("Hit tests find elements and their most specific anchors")
    func hitTests() throws {
        let scene = roomScene(WallTime(hour: 10, minute: 0))
        let a = try #require(scene.layout).anchors
        func hit(_ name: String) -> Hit? { scene.hitTest(a.point(name)!) }
        #expect(hit("monitor.power")?.element == "monitor" && hit("monitor.power")?.part == "monitor.power")
        #expect(hit("monitor.screen")?.part == "monitor.screen")
        #expect(hit("riser.drawerL.handle")?.part == "riser.drawerL.handle")
        #expect(hit("riser.cubby")?.element == "riser")
        #expect(hit("cabinet.top.handle")?.part == "cabinet.top.handle")
        #expect(hit("cabinet.file")?.part == "cabinet.file")
        #expect(hit("lamp.switch")?.element == "lamp")
        #expect(hit("room.switch")?.element == "room.switch")
        #expect(hit("keyboard")?.element == "keyboard")
        #expect(hit("wastebasket.mouth")?.element == "wastebasket")
        #expect(hit("chair")?.element == "chair")
        #expect(hit("clock")?.element == "clock")
        #expect(scene.hitTest(scene.layout!.point(ArtPoint(170, 192)))?.part == "mat.default")
        // Bare wall answers with the room itself; empty pixels inside a sprite's box fall through.
        let wall = scene.hitTest(ArtPoint(scene.layout!.coreOrigin.x + 260, scene.layout!.coreOrigin.y + 4))
        #expect(wall?.element == "room" && wall?.part == nil)
        let besideLampArm = scene.layout!.point(ArtPoint(150, 140))
        #expect(scene.hitTest(besideLampArm)?.element == "room")
    }

    @Test("Hover changes are reported once; the wall clears the ring")
    func hover() throws {
        let scene = roomScene(WallTime(hour: 10, minute: 0))
        let p = try #require(scene.layout?.anchors.point("monitor.power"))
        let ev = { (q: ArtPoint) in InputEvent(.move, art: SIMD2(Float(q.x) + 0.5, Float(q.y) + 0.5)) }
        #expect(scene.handle(ev(p)))
        #expect(!scene.handle(ev(p)))
        #expect(scene.room?.hovered?.part == "monitor.power")
        #expect(scene.handle(ev(ArtPoint(scene.layout!.coreOrigin.x + 260, scene.layout!.coreOrigin.y + 4))))
        #expect(scene.room?.hovered == nil)
        #expect(!scene.handle(InputEvent(.down, art: SIMD2(1, 1), clickCount: 1)))
        #expect(!scene.needsFrames)
    }

    @Test("The power button's hover ring hugs the button and stays inside the chin")
    func powerRing() throws {
        let scene = roomScene(WallTime(hour: 10, minute: 0))
        let layout = try #require(scene.layout)
        let r = RoomContent.ringRect(part: "monitor.power", hit: try #require(layout.anchors["monitor.power"]), layout: layout)
        #expect(layout.rect(CoreLayout.chin).insetBy(1, 1).contains(r))
        #expect(r.contains(layout.rect(CoreLayout.power)))
    }

    @Test("The lamp's painted light belongs to the room (never hit as the lamp) and goes when the room lights up")
    func lampGlowPlacements() throws {
        let scene = roomScene(WallTime(hour: 22, minute: 0), lights: .lampOnly)
        let layout = try #require(scene.layout)
        let pool = layout.rect(CoreLayout.lampPool)
        #expect(scene.hitTest(ArtPoint(pool.midX, pool.midY))?.element == "room")
        func poolImage() -> PixelBuffer? {
            scene.room?.elements.first { $0.id == "room" }?.placements.first { $0.id == "glow.lampPool" }?.image
        }
        #expect(try #require(poolImage()).opaqueBounds() != .zero)
        scene.lightsMode = .auto
        #expect(try #require(poolImage()).opaqueBounds() == .zero)
    }

    @Test("A new minute only redraws the clock, window and calendar; a new phase relights")
    func minuteRefresh() throws {
        let scene = roomScene(WallTime(hour: 10, minute: 0))
        let before = try #require(scene.room).elements.first { $0.id == "clock" }!.placements[0].image
        scene.clock = .fixed(WallTime(hour: 10, minute: 1))
        #expect(scene.roomState?.time.minute == 1)
        let after = scene.room!.elements.first { $0.id == "clock" }!.placements[0].image
        #expect(before != after)
        #expect(scene.lighting.ambient == AmbientLight(level: 7, tint: .cool))
        scene.clock = .fixed(WallTime(hour: 22, minute: 0))
        #expect(scene.lighting.ambient == AmbientLight(level: 6, tint: .warm))
        scene.lightsMode = .lampOnly
        #expect(scene.lighting.ambient == AmbientLight(level: 1, tint: .cool))
        #expect(!scene.refreshState())
    }
}

@Suite("Room snapshot", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct RoomSnapshotTests {
    let gpu: GPU
    let grid = PixelGrid(display: calibrationDisplay)

    init() throws {
        gpu = try GPU()
    }

    func render(_ time: WallTime, lights: LightsMode = .auto) throws -> (SceneHost, PixelBuffer) {
        let host = try SceneHost(grid: grid, device: gpu.device)
        host.scene.clock = .fixed(time)
        host.scene.lightsMode = lights
        host.scene.connect(presenter: host.presenter)
        let driver = OffscreenDriver(host: host)
        driver.run(frames: 1)
        return (host, try driver.snapshot())
    }

    @Test("10:00 and 22:00 match their goldens; every pixel is a palette colour", arguments: [10, 22])
    func golden(hour: Int) throws {
        let (_, frame) = try render(WallTime(hour: hour, minute: 0))
        #expect(frame.size == ArtSize(588, 383))
        #expect(frame.pixels.allSatisfy { Apollo.index(of: $0) != nil })
        #expect(Golden.match(frame, "room-1470x956@2-\(hour)00"))
    }

    @Test("SpriteKit + lit pass equal the CPU room plan (unlit and lit), day, night and Lamp Only",
          arguments: [(10, LightsMode.auto), (22, .auto), (22, .lampOnly), (18, .auto)])
    func matchesCPU(hour: Int, lights: LightsMode) throws {
        let time = WallTime(hour: hour, minute: 0)
        let (host, lit) = try render(time, lights: lights)
        let layout = try #require(host.scene.layout)
        let state = try #require(host.scene.roomState)
        #expect(state.time == time && state.lightsMode == lights)
        let art = try host.presenter.readArtFrame()
        let cpuArt = RoomPlan.compose(layout, state)
        #expect(art == cpuArt, "\(diffCount(art, cpuArt)) unlit px differ")
        let cpuLit = RoomPlan.render(layout, state)
        #expect(lit == cpuLit, "\(diffCount(lit, cpuLit)) lit px differ")
    }

    @Test("A grid change rebuilds the room for the new canvas")
    func regrid() throws {
        let (host, _) = try render(WallTime(hour: 10, minute: 0))
        let wide = PixelGrid(display: DisplayGeometry(widthPt: 1920, heightPt: 1080, backingScale: 1, topInsetPt: 25))
        try host.setGrid(wide)
        #expect(host.scene.layout?.canvas == ArtSize(640, 360))
        let driver = OffscreenDriver(host: host)
        driver.run(frames: 1)
        let frame = try driver.snapshot()
        #expect(frame == RoomPlan.render(host.scene.layout!, host.scene.roomState!))
    }
}
