import Testing
@testable import DeskCore

/// Screen light (M10 review, Errata 15): in a dark room the monitor's and phone's glows are `Tint.screen`, which
/// dims like moonlight but greys wood, so a glow on the oak desk never reads as a warm lamp; the glow stays within
/// the riser's width; under the night room light metal stays grey.
@Suite("Screen light")
struct ScreenLightTests {
    let ramp = LightRamp.shared
    let layout = LayoutSolver.solve(display: pixelGridDesignTable[0].display(dock: .hidden))

    private func mapped(_ ink: Ink, _ level: Int, _ tint: Tint) -> Int {
        ramp.map(ink.paletteIndex!, level: level, tint: tint)
    }

    @Test("The oak desk under a screen's glow is cool (grey, then blue at the fringe), never the felt's greys")
    func deskGreys() {
        let felt = Set([Role.feltMat, Role.feltMatLight].map { $0.paletteIndex! })
        for level in 2...5 {
            let desk = mapped(Role.desk, level, .screen)
            #expect(Apollo.oklab[desk].b <= 0, "not warm at \(level): \(desk)")
            #expect(!felt.contains(desk), "the desk never reads as felt at \(level)")
            for f in [Role.feltMat, Role.feltMatLight] {
                #expect(Apollo.oklab[mapped(f, level, .screen)].L < Apollo.oklab[desk].L, "felt reads darker at \(level)")
            }
        }
        // The bright band is the light cool grey 819796, not the salmon ad7757 that `cool` keeps.
        #expect(mapped(Role.desk, 5, .screen) == Ink.neutral6.paletteIndex! && mapped(Role.desk, 4, .screen) == Ink.neutral6.paletteIndex!)
        #expect(mapped(Role.desk, 5, .cool) == Ink.oak2.paletteIndex!)
        // No wood at all becomes a felt grey under screen light.
        for i in Array(Apollo.Ramp.oak.indices) + Array(Apollo.Ramp.walnut.indices) {
            for level in 0...7 { #expect(!felt.contains(ramp.map(i, level: level, tint: .screen)), "\(i) at \(level)") }
        }
    }

    @Test("The light woods are never warm under screen light; every other ramp dims exactly as under cool")
    func onlyWoodChanges() {
        let lightWoods = [Ink.oak3, .oak4, .oak5, .walnut4, .walnut5].map { $0.paletteIndex! }
        for i in 0..<Apollo.count {
            let own = Apollo.ramp(of: i)
            for level in 0...7 {
                let s = ramp.map(i, level: level, tint: .screen), c = ramp.map(i, level: level, tint: .cool)
                if own == .oak || own == .walnut {
                    if lightWoods.contains(i), (2...5).contains(level) {
                        #expect(Apollo.oklab[s].b <= 0.01, "\(i) at \(level) → \(s)")
                    }
                } else {
                    #expect(s == c, "\(own) \(i) at \(level)")
                }
            }
        }
    }

    @Test("Mask bytes carry the screen tint in bit 4, and the CPU lit pass uses its column")
    func encoding() {
        for tint in Tint.allCases {
            for level in 0...7 {
                #expect(LightMask.tint(of: LightMask.encode(level: level, tint: tint)) == tint)
                #expect(Int(LightMask.encode(level: level, tint: tint) & 7) == level)
            }
        }
        #expect(LightMask.encode(level: 5, tint: .screen) == 5 | LightMask.screenBit)
        var m = LightMask(size: ArtSize(2, 1))
        m.light(0, 0, level: 5, tint: .screen)
        let desk = PixelBuffer(width: 2, height: 1, fill: Role.desk.color)
        let lit = m.apply(to: desk, ambient: AmbientLevel(level: 1, tint: .cool))
        #expect(lit[0, 0] == Ink.neutral6.color)
        #expect(lit[1, 0] == LightRamp.shared.mapColor(Role.desk.color, level: 1, tint: .cool))
    }

    @Test("The monitor's and phone's glows are screen light, the monitor's within the riser's width")
    func glowShapes() {
        let tod = TimeOfDay(WallTime(hour: 22, minute: 0), mode: .lampOnly, roomLightOn: false)
        let m = LightMask.room(layout, lights: RoomLightState(lampOn: false, roomLightOn: false), time: tod)
        let riser = layout.rect(CoreLayout.riser)
        let desk = layout.point(ArtPoint(264, 186))
        #expect(m.level(desk.x, desk.y) == 5 && m.tint(desk.x, desk.y) == .screen)
        let phone = layout.point(ArtPoint(392, 170))
        #expect(m.level(phone.x, phone.y) >= 4 && m.tint(phone.x, phone.y) == .screen)
        // Nothing lit on the desk beyond a few px past the riser's ends.
        for y in riser.maxY..<(riser.maxY + CoreLayout.monitorGlowFade + 14) {
            for x in [riser.minX - 6, riser.maxX + 5] where m.level(x, y) > 0 {
                Issue.record("glow at \(x),\(y) outside the riser's width (\(riser))")
            }
        }
        // The lamp's pool and the monitor's glow do not merge into one warm shape: past the pool, the light is screen.
        let lampOn = LightMask.room(layout, lights: RoomLightState(roomLightOn: false), time: tod)
        #expect(lampOn.tint(desk.x, desk.y) == .screen)
    }

    @Test("Screen light only once the room is dark: at dusk the glows stay cool, so the tan desk is not stained grey")
    func screenOnlyInTheDark() {
        let desk = layout.point(ArtPoint(264, 186))
        let dusk = TimeOfDay(WallTime(hour: 18, minute: 10), roomLightOn: false)
        #expect(dusk.ambientLevel == 4 && LightMask.screenGlowTint(dusk) == .cool)
        let m = LightMask.room(layout, lights: RoomLightState(roomLightOn: false), time: dusk)
        #expect(m.level(desk.x, desk.y) == 5 && m.tint(desk.x, desk.y) == .cool)
        // One level over the dusk ambient, cool light keeps the desk the tan it is around the glow.
        #expect(Apollo.ramp(of: mapped(Role.desk, 5, .cool)) == Apollo.ramp(of: mapped(Role.desk, 4, .cool)))
        for (h, room) in [(22, false), (3, false)] {
            let t = TimeOfDay(WallTime(hour: h, minute: 0), roomLightOn: room)
            #expect(t.ambientLevel == 1 && LightMask.screenGlowTint(t) == .screen)
        }
        #expect(LightMask.screenGlowTint(TimeOfDay(WallTime(hour: 6, minute: 0), roomLightOn: false)) == .cool)
    }

    @Test("Under the room light at night (warm 6) walls and paper turn cream and tan, metal stays grey")
    func metalStaysGrey() {
        #expect(Apollo.ramp(of: mapped(.neutral9, 6, .warm)) == .oak)
        #expect(Apollo.ramp(of: mapped(.neutral8, 6, .warm)) == .oak)
        for metal in [Ink.neutral6, .neutral7] {
            #expect(Apollo.ramp(of: mapped(metal, 6, .warm)) == .neutral, "\(metal)")
        }
        // Under the lamp's pool (warm 5) they still warm.
        #expect(Apollo.ramp(of: mapped(.neutral7, 5, .warm)) == .oak)
    }
}
