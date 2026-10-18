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
        #expect(on.level(sky.midX - 10, sky.midY) == 7)
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

    @Test("Golden: Lamp Only at night (string lights glow, phone face-up, the lamp washes the partition's left wing)")
    func goldenLampOnly() {
        let state = RoomState(time: WallTime(hour: 22, minute: 0), lightsMode: .lampOnly)
        let m = LightMask.room(layout, lights: state.effectiveLights, time: state.timeOfDay)
        #expect(Golden.match(m.debugImage(), "lightmask-1470x956@2-lamp"))
    }

    // MARK: memos (0.3.0)

    @Test("Golden: Lamp Only with the clip light on (Erratum 31)")
    func goldenClipLight() {
        var state = RoomState(time: WallTime(hour: 22, minute: 0), lightsMode: .lampOnly)
        state.lights.clipLightOn = true
        let m = LightMask.room(layout, lights: state.effectiveLights, time: state.timeOfDay)
        #expect(Golden.match(m.debugImage(), "lightmask-1470x956@2-cliplight"))
    }

    /// The mask the scene builds for `state`: its layout without the decor put away.
    static func mask(_ state: RoomState, _ layout: SceneLayout) -> LightMask {
        LightMask.room(layout.hiding(StowCatalog.decorKinds(hiddenBy: state.stowed)), lights: state.effectiveLights,
                       time: state.timeOfDay)
    }

    @Test("Lamp wash: only while the lamp glows and the partition is out; it lights the pad, the cube and the left note")
    func lampWash() {
        let pad = layout.rect(CoreLayout.partitionPad)
        let lampOnly = RoomState(time: WallTime(hour: 22, minute: 0), lightsMode: .lampOnly)
        let m = Self.mask(lampOnly, layout)
        let ambient = lampOnly.timeOfDay.ambientLevel
        #expect(m.level(pad.midX, pad.midY) >= 5 && m.tint(pad.midX, pad.midY) == .warm)
        for r in [CoreLayout.partitionPad, CoreLayout.partitionCube, PartitionLayout.noteRect(at: ArtPoint(18, 115))] {
            #expect(DarkHit.isLit(layout.rect(r), mask: m, ambient: ambient), "\(r) lit by the lamp")
        }
        // Clipped to the left wing: nothing above the panel's top rail, nothing right of the monitor.
        let wash = layout.rect(CoreLayout.partitionLampWashClip)
        for x in wash.minX..<wash.maxX { #expect(m.level(x, wash.minY - 1) == Self.mask(Self.unwashed(lampOnly), layout).level(x, wash.minY - 1)) }
        // Put away, or with the lamp off, or by day: no wash.
        var away = lampOnly
        away.stowed = [.partition]
        #expect(Self.mask(away, layout).level(pad.midX, pad.midY) == 0)
        var dark = RoomState(time: WallTime(hour: 22, minute: 0), lights: RoomLightState(lampOn: false, roomLightOn: false))
        #expect(Self.mask(dark, layout).level(pad.midX, pad.midY) == 0)
        dark.lights.lampOn = true
        #expect(Self.mask(dark, layout).level(pad.midX, pad.midY) >= 5)
        #expect(Self.mask(RoomState(time: WallTime(hour: 10, minute: 0)), layout).level(pad.midX, pad.midY) == 0)
        // The room light on at night (ambient 6): the lamp's light does not show, nor does its wash.
        #expect(Self.mask(RoomState(time: WallTime(hour: 22, minute: 0)), layout).level(pad.midX, pad.midY) == 0)
    }

    /// `state` with the partition put away (the mask without the wash, for comparing outside it).
    static func unwashed(_ state: RoomState) -> RoomState {
        var s = state
        s.stowed = [.partition]
        return s
    }

    @Test("Clip light: its bulb glows when it is on and out; after dark it lights the tower and the right wing only")
    func clipLight() {
        var state = RoomState(time: WallTime(hour: 22, minute: 0), lightsMode: .lampOnly)
        let bulb = layout.rect(CoreLayout.partitionClipBulb)
        let ambient = state.timeOfDay.ambientLevel
        #expect(Self.mask(state, layout).level(bulb.x, bulb.y) == 0, "off by default")
        state.lights.clipLightOn = true
        let m = Self.mask(state, layout)
        #expect(m.level(bulb.x, bulb.y) == 7 && m.tint(bulb.x, bulb.y) == .warm)
        let clips = layout.rect(CoreLayout.partitionClips)
        #expect(m.level(clips.midX, clips.midY) >= 5)
        for p in PartitionLayout.defaultSpots.prefix(7) {
            #expect(DarkHit.isLit(layout.rect(PartitionLayout.noteRect(at: p)), mask: m, ambient: ambient), "\(p)")
        }
        // Not on the wall around the tower: right of it, above it.
        let tower = layout.rect(CoreLayout.partitionTower)
        #expect(m.level(tower.maxX + 4, tower.midY) == 0 && m.level(tower.midX, tower.minY - 2) == 0)
        // Lamp Only leaves it as set; put away (or its partition), it is dark.
        for away in [StowID.clipLight, .partition] {
            var s = state
            s.stowed = [away]
            #expect(!s.effectiveLights.clipLightOn)
            #expect(Self.mask(s, layout).level(bulb.x, bulb.y) == 0 && Self.mask(s, layout).level(clips.midX, clips.midY) == 0)
        }
        // By day only the bulb glows.
        var day = RoomState(time: WallTime(hour: 10, minute: 0))
        day.lights.clipLightOn = true
        let d = Self.mask(day, layout)
        #expect(d.level(bulb.x, bulb.y) == 7 && d.level(clips.midX, clips.midY) == 0)
    }

    @Test("By day the partition lights nothing but a switched-on bulb; put away, its lights are gone at night")
    func dayUnchanged() {
        var day = RoomState(time: WallTime(hour: 10, minute: 0))
        let plain = Self.mask(day, layout)
        day.stowed = [.partition]
        #expect(Self.mask(day, layout) == plain)
        day.stowed = []
        day.lights.clipLightOn = true
        var bulbOnly = plain
        bulbOnly.addRect(layout.rect(CoreLayout.partitionClipBulb), level: 7, tint: .warm)
        #expect(Self.mask(day, layout) == bulbOnly)
        var night = RoomState(time: WallTime(hour: 22, minute: 0), lightsMode: .lampOnly)
        night.lights.clipLightOn = true
        night.stowed = [.partition, .stringLights, .phoneStand]
        let m = Self.mask(night, layout)
        #expect(m.level(layout.rect(CoreLayout.partitionPad).midX, layout.rect(CoreLayout.partitionPad).midY) == 0)
        for d in layout.decor(.stringLights) {
            for p in RoomArt.stringLightGlass(in: d.rect) { #expect(m.level(p.x, p.y) == 0) }
        }
        let phone = layout.rect(PropArt.phoneScreenRect)
        #expect(m.level(phone.midX, phone.midY) == 0, "no glow from a phone put away")
    }
}
