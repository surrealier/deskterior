import Testing
@testable import DeskCore

@Suite("Light mask")
struct LightMaskTests {
    let layout = LayoutSolver.solve(display: pixelGridDesignTable[0].display(dock: .hidden))

    @Test("Byte encoding: low 3 bits level, bit 3 warm; brighter light wins")
    func encoding() {
        #expect(LightMask.encode(level: 7, tint: .warm) == 15)
        #expect(LightMask.encode(level: 5, tint: .cool) == 5)
        #expect(LightMask.encode(level: 9, tint: .cool) == 7)
        var m = LightMask(size: ArtSize(4, 4))
        m.addRect(ArtRect(0, 0, 4, 4), level: 4, tint: .cool)
        m.addRect(ArtRect(1, 1, 2, 2), level: 6, tint: .warm)
        m.addRect(ArtRect(0, 0, 2, 2), level: 2, tint: .warm)
        #expect(m.level(0, 0) == 4 && m.tint(0, 0) == .cool)
        #expect(m.level(1, 1) == 6 && m.tint(1, 1) == .warm)
        #expect(m.level(9, 9) == 0)
    }

    @Test("Trapezoid: solid inside, Bayer-thinned fringe of `edge` px, nothing beyond")
    func trapezoidFringe() {
        var m = LightMask(size: ArtSize(64, 40))
        m.addTrapezoid(top: (20, 44, 0), bottom: (20, 44, 30), level: 7, tint: .warm)
        for y in 0..<30 { for x in 20..<44 { #expect(m.level(x, y) == 7) } }
        // Fringe columns get sparser away from the edge; 4+ px out nothing is lit.
        func litCount(column x: Int) -> Int { (0..<30).filter { m.level(x, $0) == 7 }.count }
        #expect(litCount(column: 19) > litCount(column: 17))
        #expect(litCount(column: 17) > 0)
        #expect(litCount(column: 15) == 0 && litCount(column: 48) == 0)
        #expect((0..<64).allSatisfy { m.level($0, 34) == 0 })
        #expect(m.tint(30, 10) == .warm)
    }

    @Test("Ellipse glow: solid core, dithered rim")
    func ellipse() {
        var m = LightMask(size: ArtSize(40, 40))
        m.addEllipse(ArtRect(10, 10, 20, 20), level: 6, tint: .warm)
        #expect(m.level(20, 20) == 6 && m.level(11, 20) == 6)
        #expect(m.level(0, 0) == 0 && m.level(39, 39) == 0)
    }

    @Test("Room mask: screen, LED and sky emissive; lamp warm; nothing else when lights are off")
    func roomSources() {
        let tod = TimeOfDay(WallTime(hour: 22, minute: 0), roomLightOn: false)
        let on = LightMask.room(layout, lights: RoomLightState(), time: tod)
        let screen = layout.rect(CoreLayout.screen)
        #expect(on.level(screen.midX, screen.midY) == 7)
        let led = layout.rect(CoreLayout.led)
        #expect(on.level(led.x, led.y) == 7)
        let sky = layout.rect(WindowArt.skyRect(in: CoreLayout.window))
        #expect(on.level(sky.midX, sky.midY) == 7)
        let pool = layout.point(ArtPoint(180, 220))
        #expect(on.level(pool.x, pool.y) == 7 && on.tint(pool.x, pool.y) == .warm)

        let off = LightMask.room(layout, lights: RoomLightState(lampOn: false, monitorOn: false, phoneFaceUp: false), time: tod)
        #expect(off.level(screen.midX, screen.midY) == 0)
        #expect(off.level(pool.x, pool.y) == 0)
        #expect(off.level(led.x, led.y) == 7)   // the standby LED still glows
        #expect(off.bytes.allSatisfy { $0 & LightMask.warmBit == 0 || $0 & 7 == 7 })
    }

    @Test("CPU lit pass: identity at ambient 7; the mask lifts dark rooms back to full colour")
    func applyPass() {
        var img = PixelBuffer(width: 4, height: 1)
        for x in 0..<4 { img[x, 0] = Ink(palette: 14 + x).color }
        var m = LightMask(size: ArtSize(4, 1))
        #expect(m.apply(to: img, ambient: AmbientLevel(level: 7, tint: .cool)) == img)
        m.addRect(ArtRect(0, 0, 2, 1), level: 7, tint: .warm)
        let dark = m.apply(to: img, ambient: AmbientLevel(level: 1, tint: .cool))
        #expect(dark[0, 0] == img[0, 0] && dark[1, 0] == img[1, 0])
        #expect(dark[2, 0] == LightRamp.shared.mapColor(img[2, 0], level: 1, tint: .cool))
    }

    @Test("Golden: this Mac's room mask by day, everything on")
    func goldenDay() {
        let tod = TimeOfDay(WallTime(hour: 10, minute: 0), roomLightOn: true)
        let m = LightMask.room(layout, lights: RoomLightState(), time: tod)
        #expect(Golden.match(m.debugImage(), "lightmask-1470x956@2-day"))
    }

    @Test("Golden: Lamp Only at night (string lights glow, phone face-up)")
    func goldenLampOnly() {
        let state = RoomState(time: WallTime(hour: 22, minute: 0), lightsMode: .lampOnly)
        let m = LightMask.room(layout, lights: state.effectiveLights, time: state.timeOfDay)
        #expect(Golden.match(m.debugImage(), "lightmask-1470x956@2-lamp"))
    }
}
