import DeskPixels
import Testing
@testable import DeskCore

@Suite("Art catalog")
struct ArtCatalogTests {
    static let sprites = ArtCatalog.all()

    @Test("Every sprite: frames of one size, binary alpha, every pixel an Apollo colour")
    func everySpriteIsOnPalette() {
        #expect(Self.sprites.count > 90)
        for s in Self.sprites {
            #expect(s.size.w > 0 && s.size.h > 0, "\(s.name) is empty")
            #expect(s.frames.allSatisfy { $0.size == s.size }, "\(s.name) frame sizes differ")
            for (i, f) in s.frames.enumerated() {
                #expect(f.pixels.allSatisfy { $0 == .clear || Apollo.index(of: $0) != nil },
                        "\(s.name) frame \(i) has an off-palette or partially transparent pixel")
                #expect(f.opaqueBounds() != .zero, "\(s.name) frame \(i) is blank")
            }
            // Round-trips through IndexedSprite exactly (only palette inks).
            #expect(IndexedSprite(exactly: s.image) != nil, "\(s.name)")
        }
    }

    @Test("Names are unique per section")
    func uniqueNames() {
        for section in ArtCatalog.sections() {
            let names = section.sprites.map(\.name)
            #expect(Set(names).count == names.count, "duplicate names in \(section.title): \(names)")
        }
    }

    @Test("Sizes match the composition rects (§1.3)")
    func sizes() {
        #expect(MonitorArt.body().size == CoreLayout.monitorBody.size)
        #expect(MonitorArt.deskOSWallpaper().size == CoreLayout.screen.size)
        #expect(StorageArt.riser().size == CoreLayout.riser.size)
        #expect(StorageArt.riserDrawer(p: 0).size == ArtSize(56, 12 + CoreLayout.riserTravel))
        #expect(StorageArt.cabinet().size == ArtSize(80, 2 + 64 + 18))
        #expect(PropArt.keyboard().size == CoreLayout.keyboard.size)
        #expect(PropArt.brush().size == CoreLayout.brush.size && PropArt.brush().frameCount == 2)
        #expect(PropArt.chair().size == CoreLayout.chair.size)
        #expect(PropArt.plant().size == CoreLayout.plant.size)
        #expect(PropArt.penCup().size == CoreLayout.penCup.size)
        #expect(PropArt.phoneStand(faceUp: true).size == CoreLayout.phone.size)
        #expect(PropArt.driveHub().size == CoreLayout.driveHub.size)
        #expect(PropArt.wastebasketFront().size == CoreLayout.wastebasket.size)
        #expect(PropArt.paperBall(0).size == ArtSize(8, 8))
        #expect(InteriorRaster.basketSlots.count == ContainerSpec.wastebasket.hardCap)
        #expect(WindowArt.window(sky: .day, minuteOfDay: 0).size == CoreLayout.window.size)
        #expect(RoomArt.clock(hour: 1, minute: 2).size == CoreLayout.clock.size)
        #expect(RoomArt.calendar(WallTime(hour: 1, minute: 0)).size == CoreLayout.calendar.size)
        #expect(RoomArt.roomSwitch(on: true).size == CoreLayout.roomSwitch.size)
        for kind in IconKind.allCases {
            #expect(KindIcons.icon(kind).size == ArtSize(16, 16))
            #expect(KindIcons.icon(kind, size: 12).size == ArtSize(12, 12))
            #expect(KindIcons.mini(kind).size == ArtSize(5, 5))
        }
        #expect(MonitorArt.powerOffFrames(from: MonitorArt.deskOSWallpaper()).count == 6)
        #expect(MonitorArt.powerOnFrames(to: MonitorArt.deskOSWallpaper()).count == 8)
        #expect(FXArt.dustPuff().frameCount == 5 && FXArt.squash(KindIcons.icon(.doc).image).frameCount == 3)
        #expect(PropArt.PhoneFace.allCases.count == 5)
    }

    @Test("State changes the pixels: clock hands, LED, lamp, drawers, phone, sky")
    func statesDiffer() {
        #expect(RoomArt.clock(hour: 10, minute: 0).image != RoomArt.clock(hour: 10, minute: 1).image)
        #expect(RoomArt.clock(hour: 3, minute: 0).image != RoomArt.clock(hour: 9, minute: 0).image)
        #expect(MonitorArt.led(.on).image != MonitorArt.led(.amber).image)
        #expect(PropArt.lamp(on: true).image != PropArt.lamp(on: false).image)
        #expect(StorageArt.riserDrawer(p: 0).image != StorageArt.riserDrawer(p: 5).image)
        #expect(StorageArt.riserDrawer(p: 5).image != StorageArt.riserDrawer(p: 5, jammed: true).image)
        #expect(StorageArt.cabinet().image != StorageArt.cabinet(p: [0, 0, 9]).image)
        #expect(PropArt.phoneStand(faceUp: true).image != PropArt.phoneStand(faceUp: false).image)
        let skies = SkyVariant.allCases.map { WindowArt.window(sky: $0, minuteOfDay: 600).image }
        #expect(Set(skies.map(\.pixels)).count == skies.count)
        // Clouds drift with the minutes.
        #expect(WindowArt.window(sky: .day, minuteOfDay: 600).image != WindowArt.window(sky: .day, minuteOfDay: 601).image)
    }

    @Test("A drawer's front slides down p rows and the interior shows above it")
    func drawerTravel() {
        let closed = StorageArt.riserDrawer(p: 0).image, open = StorageArt.riserDrawer(p: 6).image
        #expect(closed.cropped(to: ArtRect(0, 0, 56, 12)) == open.cropped(to: ArtRect(0, 6, 56, 12)))
        #expect(closed.cropped(to: ArtRect(0, 12, 56, 10)).opaqueBounds() == .zero)
        #expect(open.cropped(to: ArtRect(0, 0, 56, 6)).pixels.allSatisfy { $0.a == 255 })
    }

    @Test("Room plan: unique ids, everything on the canvas, layers in order")
    func roomPlan() {
        let layout = LayoutSolver.solve(display: pixelGridDesignTable[0].display(dock: .hidden))
        let plan = RoomPlan.placements(layout, RoomState(time: WallTime(hour: 10, minute: 0)))
        let ids = plan.map(\.id)
        #expect(Set(ids).count == ids.count)
        let canvas = ArtRect(0, 0, layout.canvas.w, layout.canvas.h)
        for p in plan where p.id != "cabinet" {
            #expect(canvas.contains(p.rect), "\(p.id) \(p.rect)")
        }
        #expect(zip(plan, plan.dropFirst()).allSatisfy { $0.layer <= $1.layer })
        let partial = RoomPlan.placements(layout, RoomState(time: WallTime(hour: 10, minute: 0)), only: RoomPlan.minuteIDs)
        #expect(Set(partial.map(\.id)) == RoomPlan.minuteIDs)
    }

    @Test("Wallpaper pixelator: aspect-fill crop, palette output, allowlisted folders only")
    func wallpaper() {
        #expect(WallpaperPixelator.aspectFillCrop(ArtSize(400, 100), to: ArtSize(196, 108)) == ArtRect(109, 0, 181, 100))
        #expect(WallpaperPixelator.aspectFillCrop(ArtSize(100, 400), to: ArtSize(196, 108)) == ArtRect(0, 172, 100, 55))
        var src = PixelBuffer(width: 64, height: 40)
        for y in 0..<40 { for x in 0..<64 { src[x, y] = RGBA8(UInt8(x * 4), UInt8(y * 6), 200) } }
        let out = WallpaperPixelator.pixelate(src, to: ArtSize(32, 18), colors: 8)
        #expect(out.size == ArtSize(32, 18))
        #expect(out.pixels.allSatisfy { Apollo.index(of: $0) != nil })
        #expect(Set(out.pixels).count <= 8)
        #expect(WallpaperPixelator.isAllowed(realPath: "/System/Library/Desktop Pictures/Sonoma.heic"))
        #expect(WallpaperPixelator.isAllowed(realPath: "/Library/Desktop Pictures/x.jpg"))
        #expect(!WallpaperPixelator.isAllowed(realPath: "/Library/Desktop Pictures Evil/x.jpg"))
        #expect(!WallpaperPixelator.isAllowed(realPath: "/Users/me/Pictures/x.jpg"))
    }
}
