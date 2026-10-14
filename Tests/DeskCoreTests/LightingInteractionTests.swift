import Testing
@testable import DeskCore

/// M10 (DESIGN §2.2 E12–E13, Errata 8): Lamp Only as a menu choice and as an emergent state, the glows that
/// follow the monitor and phone, the softened light shapes, and the light query behind dark-token filtering.
@Suite("Lighting interactions")
struct LightingInteractionTests {
    typealias F = ModelFixture
    let layout = LayoutSolver.solve(display: pixelGridDesignTable[0].display(dock: .hidden))

    private func reduced(_ s: DeskState, _ a: DeskAction) -> DeskState {
        var copy = s
        _ = reduce(&copy, a, ReduceEnv(now: F.t0))
        return copy
    }

    private func pick(_ command: MenuCommand, _ s: DeskState) -> DeskState {
        guard let a = command.action(s) else { Issue.record("no action for \(command)"); return s }
        return reduced(s, a)
    }

    @Test("Lights ▸ Lamp Only sets all three at once: night, room light off, lamp on")
    func lampOnlyFromTheMenu() {
        var s = F.mirrored(["a"])
        s.lights = LightsState(mode: .auto, room: true, lamp: false)
        let lamp = pick(.lightsMode(.lampOnly), s)
        #expect(lamp.lights == .lampOnly)
        #expect(lamp.lights == LightsState(mode: .lampOnly, room: false, lamp: true))
        // A demo's or `--lights lamp`'s action (mode only) settles the same way.
        if let a = DemoStep.action(named: "lights:lamp", in: s) { #expect(reduced(s, a).lights == .lampOnly) }
        let tod = RoomState(time: WallTime(hour: 10, minute: 0), lightsMode: lamp.lights.mode,
                            lights: RoomLightState(lampOn: lamp.lights.lamp, roomLightOn: lamp.lights.room)).timeOfDay
        #expect(tod.phase == .night && tod.ambientLevel == 1)
    }

    @Test("Emergent: switching the room light or the lamp leaves Lamp Only for Night, and back")
    func emergent() {
        var s = F.mirrored(["a"])
        s.lights = .lampOnly
        // The wall switch: room light on → plain Night (warm room); off again → Lamp Only again.
        let roomOn = reduced(s, .lights(s.lights.withRoomLight(true)))
        #expect(roomOn.lights == LightsState(mode: .night, room: true, lamp: true))
        let back = reduced(roomOn, .lights(roomOn.lights.withRoomLight(false)))
        #expect(back.lights == .lampOnly)
        // The lamp off → Night with everything off; on again → Lamp Only.
        let dark = reduced(s, .lights(s.lights.withLamp(false)))
        #expect(dark.lights == LightsState(mode: .night, room: false, lamp: false))
        #expect(reduced(dark, .lights(dark.lights.withLamp(true))).lights == .lampOnly)
        // Night with the room light switched off and the lamp on is Lamp Only.
        var night = s
        night.lights = LightsState(mode: .night, room: true, lamp: true)
        #expect(pick(.roomLight(false), night).lights == .lampOnly)
        // Auto stays Auto whatever the switches do (the clock may bring the day).
        var auto = s
        auto.lights = LightsState(mode: .auto, room: true, lamp: true)
        #expect(pick(.roomLight(false), auto).lights == LightsState(mode: .auto, room: false, lamp: true))
    }

    @Test("Choosing another mode from Lamp Only turns the room light back on; the menu's switches stay live")
    func leavingLampOnly() {
        var s = F.mirrored(["a"])
        s.lights = .lampOnly
        for mode in [LightsMode.auto, .day, .night] {
            #expect(pick(.lightsMode(mode), s).lights == LightsState(mode: mode, room: true, lamp: true), "\(mode)")
        }
        let menu = MenuSpec.desk(s)
        #expect(menu.item("lights.lamp")?.isChecked == true)
        #expect(menu.item("lights.room")?.isEnabled == true && menu.item("lights.room")?.isChecked == false)
        #expect(menu.item("lights.deskLamp")?.isEnabled == true && menu.item("lights.deskLamp")?.isChecked == true)
        #expect(pick(menu.item("lights.room")!.command!, s).lights == LightsState(mode: .night, room: true, lamp: true))
        #expect(pick(menu.item("lights.deskLamp")!.command!, s).lights == LightsState(mode: .night, room: false, lamp: false))
        // An older layout's Lamp Only kept the switches as they were: it still shows (and toggles) as Lamp Only.
        var legacy = s
        legacy.lights = LightsState(mode: .lampOnly, room: true, lamp: false)
        #expect(!legacy.lights.roomLightOn && legacy.lights.lampLit)
        #expect(MenuSpec.desk(legacy).item("lights.room")?.isChecked == false)
        #expect(pick(MenuSpec.desk(legacy).item("lights.room")!.command!, legacy).lights.mode == .night)
        // Re-choosing the current mode changes nothing.
        #expect(reduce(&s, .lights(.lampOnly), ReduceEnv(now: F.t0)).isEmpty)
    }

    @Test("The monitor's glow goes with the display; its glass may still glow (CRT); the phone's follows the face")
    func glowsFollowState() {
        let tod = TimeOfDay(WallTime(hour: 22, minute: 0), mode: .lampOnly, roomLightOn: false)
        let desk = layout.point(ArtPoint(264, 186))        // in front of the riser, under the screen's middle
        let screen = layout.rect(CoreLayout.screen)
        let phoneGlow = layout.point(ArtPoint(392, 170))
        let on = LightMask.room(layout, lights: RoomLightState(lampOn: false, roomLightOn: false), time: tod)
        #expect(on.level(desk.x, desk.y) == 5 && on.tint(desk.x, desk.y) == .screen)
        #expect(on.level(screen.midX, screen.midY) == 7)
        #expect(on.level(phoneGlow.x, phoneGlow.y) >= 4)
        let collapsing = LightMask.room(layout, lights: RoomLightState(lampOn: false, roomLightOn: false, monitorGlows: false),
                                        time: tod)
        #expect(collapsing.level(desk.x, desk.y) == 0, "no glow while the CRT collapses")
        #expect(collapsing.level(screen.midX, screen.midY) == 7, "the collapsing picture still glows on the glass")
        let off = LightMask.room(layout, lights: RoomLightState(lampOn: false, monitorOn: false, roomLightOn: false), time: tod)
        #expect(off.level(desk.x, desk.y) == 0 && off.level(screen.midX, screen.midY) == 0)
        let down = LightMask.room(layout, lights: RoomLightState(lampOn: false, phoneFaceUp: false, roomLightOn: false), time: tod)
        #expect(down.level(phoneGlow.x, phoneGlow.y) == 0)
        #expect(RoomLightState(monitorOn: false).monitorGlows == false && RoomLightState().monitorGlows)
    }

    @Test("The lamp's pool steps down 7 → 6 → 5 → 4 → 3 → 2 in dithered bands, warm, palette levels only")
    func softPool() {
        let tod = TimeOfDay(WallTime(hour: 22, minute: 0), mode: .lampOnly, roomLightOn: false)
        let m = LightMask.room(layout, lights: RoomLightState(roomLightOn: false), time: tod)
        let pool = layout.rect(CoreLayout.lampPool)
        let cy = pool.midY
        // Walking left from the centre (away from the monitor's glow) every step down is there.
        let levels = stride(from: pool.midX, through: pool.minX - 60, by: -1).map { m.level($0, cy) }
        let seen = Set(levels)
        #expect(seen.isSuperset(of: [2, 3, 4, 5, 6, 7]), "\(seen.sorted())")
        #expect(levels.first == 7)
        #expect(m.tint(pool.midX, cy) == .warm && m.tint(pool.minX - 4, cy) == .warm)
        // Outside the falloff the room is at ambient (mask 0).
        #expect(m.level(pool.minX - 50, cy) == 0)
        // The rim is no longer a hard 6-to-ambient edge: just past it the light is at 4–5.
        #expect((4...5).contains(m.level(pool.minX - 4, cy)))
    }

    @Test("Dark-token rule: lit when a third of the token's pixels reach level 3 (mask or ambient)")
    func darkHitRule() {
        var m = LightMask(size: ArtSize(32, 16))
        m.addRect(ArtRect(0, 0, 8, 16), level: 7, tint: .warm)
        m.addRect(ArtRect(8, 0, 4, 16), level: 2, tint: .cool)
        #expect(m.litFraction(ArtRect(0, 0, 16, 16), atLeast: 3, ambient: 1) == 0.5)
        #expect(DarkHit.isLit(ArtRect(0, 0, 16, 16), mask: m, ambient: 1))
        #expect(!DarkHit.isLit(ArtRect(4, 0, 16, 16), mask: m, ambient: 1), "a quarter is not enough")
        #expect(!DarkHit.isLit(ArtRect(16, 0, 16, 16), mask: m, ambient: 1))
        #expect(DarkHit.isLit(ArtRect(16, 0, 16, 16), mask: m, ambient: 3), "ambient 3 lights everything")
        #expect(!DarkHit.isLit(ArtRect(40, 0, 16, 16), mask: m, ambient: 7), "off the canvas")
        #expect(m.effectiveLevel(20, 4, ambient: 1) == 1 && m.effectiveLevel(2, 4, ambient: 1) == 7)

        let tod = TimeOfDay(WallTime(hour: 22, minute: 0), mode: .lampOnly, roomLightOn: false)
        let room = LightMask.room(layout, lights: RoomLightState(roomLightOn: false), time: tod)
        func token(_ core: ArtPoint) -> ArtRect { ArtRect(origin: layout.point(core) - ArtPoint(8, 8), size: ArtSize(16, 16)) }
        #expect(DarkHit.isLit(token(ArtPoint(170, 207)), mask: room, ambient: tod.ambientLevel), "in the pool")
        #expect(DarkHit.isLit(token(ArtPoint(264, 186)), mask: room, ambient: tod.ambientLevel), "in the monitor's glow")
        #expect(DarkHit.isLit(token(ArtPoint(392, 168)), mask: room, ambient: tod.ambientLevel), "by the phone")
        #expect(DarkHit.isLit(layout.rect(CoreLayout.screenCellRect(col: 4, row: 2)), mask: room, ambient: tod.ambientLevel))
        #expect(!DarkHit.isLit(token(ArtPoint(100, 295)), mask: room, ambient: tod.ambientLevel), "on the floor")
        #expect(!DarkHit.isLit(token(ArtPoint(470, 215)), mask: room, ambient: tod.ambientLevel), "the desk's far end")
    }

    @Test("Keyboard keys: every cap is findable, gaps belong to the key on their left, off the plate nothing")
    func keyboardKeys() {
        #expect(PropArt.keyboardKeys.count == 17 + 16 + 16 + 9)
        for k in PropArt.keyboardKeys {
            let p = ArtPoint(k.rect.midX, k.rect.midY)
            #expect(PropArt.keyboardKey(at: p).map { $0.row == k.row && $0.col == k.col } == true)
        }
        #expect(PropArt.keyboardKey(at: ArtPoint(0, 0)) == nil && PropArt.keyboardKey(at: ArtPoint(50, 13)) == nil)
        let space = PropArt.keyboardKeys.first { $0.row == 3 && $0.col == 3 }!
        #expect(space.rect.w == 45)
        // The pressed sprite moves exactly that cap.
        let up = PropArt.keyboard().image, down = PropArt.keyboard(pressed: (3, 3)).image
        let changed = (0..<up.height).flatMap { y in (0..<up.width).filter { up.pixel($0, y) != down.pixel($0, y) }.map { ArtPoint($0, y) } }
        #expect(!changed.isEmpty && changed.allSatisfy { space.rect.contains($0) })
    }

    @Test("Window (M3, checked for M10): the sky follows the phase, clouds drift 1 px a minute, the moon at night")
    func window() {
        let size = ArtSize(72, 82)
        let a = WindowArt.skyImage(.day, size: size, minuteOfDay: 600), b = WindowArt.skyImage(.day, size: size, minuteOfDay: 601)
        // The clouds' rows: what was at x is at x + 1 a minute later (away from the cloud wrap at the edges).
        let cloudRow = 36
        let moved = (10..<60).filter { a.pixel($0, cloudRow) != b.pixel($0, cloudRow) }
        #expect(!moved.isEmpty && moved.allSatisfy { b.pixel($0 + 1, cloudRow) == a.pixel($0, cloudRow) || b.pixel($0, cloudRow) == a.pixel($0 - 1, cloudRow) })
        let night = WindowArt.skyImage(.night, size: size, minuteOfDay: 1320)
        #expect(night.pixels.contains(Ink.walnut5.color), "the moon")
        #expect(night != WindowArt.skyImage(.dusk, size: size, minuteOfDay: 1320))
        #expect(RoomState(time: WallTime(hour: 22, minute: 0)).sky == .night)
        #expect(RoomState(time: WallTime(hour: 18, minute: 0)).sky == .dusk)
    }

    @Test("Plant jiggle: frames 0–2 sway the blade tips, frame 3 is the plant at rest, the pot never moves, no tip is cut off")
    func plantJiggle() {
        let still = PropArt.plant().image
        let pad = PropArt.plantJigglePad
        var rest = PixelBuffer(width: still.width + 2 * pad, height: still.height)
        rest.blit(still, at: ArtPoint(pad, 0))
        #expect(PropArt.plantJiggle(3) == rest)
        for f in 0..<3 {
            let j = PropArt.plantJiggle(f)
            #expect(j != rest, "frame \(f)")
            #expect(j.size == rest.size)
            for y in 20..<rest.height { for x in 0..<rest.width { #expect(j.pixel(x, y) == rest.pixel(x, y)) } }
            // Every blade pixel lands somewhere (a 1-px sway at the sprite's edge used to fall off it).
            for y in 0..<rest.height {
                let row = (0..<still.width).filter { still.pixel($0, y).a != 0 }.count
                let moved = (0..<j.width).filter { j.pixel($0, y).a != 0 }.count
                #expect(moved == row, "frame \(f) row \(y): \(moved) of \(row) px")
            }
        }
    }
}
