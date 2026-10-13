import Testing
@testable import DeskCore

/// 2×2 windows that form a 1-px checkerboard (a b / b a with a ≠ b) inside `r`.
func checkerWindows(_ b: PixelBuffer, in r: ArtRect) -> Int {
    var n = 0
    for y in r.minY..<(r.maxY - 1) {
        for x in r.minX..<(r.maxX - 1) {
            let a = b.pixel(x, y), c = b.pixel(x + 1, y)
            if a != c, a == b.pixel(x + 1, y + 1), c == b.pixel(x, y + 1) { n += 1 }
        }
    }
    return n
}

func inks(_ b: PixelBuffer, in r: ArtRect? = nil) -> Set<Ink> {
    let area = (r ?? b.bounds).intersection(b.bounds)
    var out = Set<Ink>()
    for y in area.minY..<area.maxY {
        for x in area.minX..<area.maxX {
            if let i = Apollo.index(of: b.pixel(x, y)) { out.insert(Ink(palette: i)) }
        }
    }
    return out
}

/// Regressions for the M3 art and UX review.
@Suite("Art review fixes")
struct ArtReviewTests {
    let mac = LayoutSolver.solve(display: pixelGridDesignTable[0].display(dock: .hidden))

    @Test("Every 16- and 12-px icon wears a 172038 outline on its silhouette edge")
    func iconOutlines() {
        for size in [16, 12] {
            for kind in IconKind.allCases {
                let b = KindIcons.icon(kind, size: size).image
                for y in 0..<b.height {
                    for x in 0..<b.width where b.pixel(x, y).a != 0 {
                        let edge = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].contains { b.pixel($0.0, $0.1).a == 0 }
                        if edge { #expect(b.pixel(x, y) == Ink.blue0.color, "\(kind) \(size) (\(x),\(y))") }
                    }
                }
            }
        }
    }

    @Test("DeskOS sky: day is 4f8fba→73bed3 only, seams sit in the token-row gutters, no checkerboards")
    func wallpaper() {
        let day = MonitorArt.deskOSWallpaper(sky: .day)
        // A cloud-free column above the hills.
        #expect(inks(day, in: ArtRect(80, 0, 1, 72)) == [.blue3, .blue4])
        for seam in MonitorArt.skySeams {
            let y = CoreLayout.screen.y + seam
            for row in 0..<CoreLayout.screenRows {
                let icon = CoreLayout.screenCellRect(col: 0, row: row).insetBy(2, 2)
                #expect(!(icon.minY - 1...icon.maxY).contains(y), "seam at core y \(y) crosses token row \(row)")
            }
        }
        for sky in SkyVariant.allCases {
            let w = MonitorArt.deskOSWallpaper(sky: sky)
            #expect(checkerWindows(w, in: w.bounds) == 0, "\(sky)")
        }
        // The night sky has no lone lamp-coloured pixels between the icons.
        #expect(!inks(MonitorArt.deskOSWallpaper(sky: .night), in: ArtRect(0, 70, 196, 38)).contains(.walnut4))
    }

    @Test("After dark only the window's glass glows, not the mullion or the blind cord")
    func windowEmissive() {
        let state = RoomState(time: WallTime(hour: 22, minute: 0), lightsMode: .lampOnly)
        let m = LightMask.room(mac, lights: state.effectiveLights, time: state.timeOfDay)
        let win = mac.rect(CoreLayout.window)
        let mullion = WindowArt.mullionX.lowerBound
        #expect(m.level(win.x + mullion, win.y + 60) == 0 && m.level(win.x + mullion + 1, win.y + 60) == 0)
        for p in WindowArt.cordPixels(railY: WindowArt.railY(bottom: WindowArt.blindsBottom)) {
            #expect(m.level(win.x + p.x, win.y + p.y) == 0, "cord \(p)")
        }
        #expect(m.level(win.x + 20, win.y + 60) == 7)
    }

    @Test("The framed print's arches stay inside the card")
    func framedPrint() {
        let size = ArtSize(32, 40)
        let b = DecorArt.frame(size).image
        let border = inks(b, in: ArtRect(0, size.h - 5, size.w, 5))
        #expect(border.isDisjoint(with: [.red4, .walnut4, .blue3, .green3]))
    }

    @Test("Without a Dock strip the core rises so floor shows under the furniture",
          arguments: pixelGridDesignTable, PixelGridDock.allCases)
    func floorMargin(_ row: PixelGridTableRow, _ dock: PixelGridDock) {
        let layout = LayoutSolver.solve(display: row.display(dock: dock))
        let below = layout.canvas.h - layout.floorY
        #expect(below >= LayoutSolver.minFloorMargin || layout.coreOrigin.y == layout.visible.minY,
                "\(row.name) \(dock): \(below) floor rows")
        #expect(layout.coreOrigin.y >= layout.visible.minY)
    }

    @Test("Glows keep the desk an oak: no desk pixel turns into the felt mat's greys")
    func glowsStayOak() {
        for mode in [LightsMode.lampOnly, .night] {
            let state = RoomState(time: WallTime(hour: 22, minute: 0), lightsMode: mode)
            let unlit = RoomPlan.compose(mac, state), lit = RoomPlan.render(mac, state)
            let desk = mac.rect(CoreLayout.deskTop)
            for y in desk.minY..<desk.maxY {
                for x in desk.minX..<desk.maxX {
                    guard let i = Apollo.index(of: unlit.pixel(x, y)), Ink(palette: i).ramp == .oak else { continue }
                    #expect(![Ink.neutral4.color, Ink.neutral5.color].contains(lit.pixel(x, y)), "\(mode) (\(x),\(y))")
                }
            }
        }
    }

    @Test("The lamp's pool: warm e8c170 centre after dark, gone when the room is lit (ambient ≥ 6)")
    func lampPool() {
        let pool = mac.rect(CoreLayout.lampPool)
        let centre = ArtPoint(pool.midX, pool.midY)
        let dark = RoomState(time: WallTime(hour: 22, minute: 0), lightsMode: .lampOnly)
        let lit = RoomPlan.render(mac, dark)
        #expect(inks(lit, in: ArtRect(centre.x - 10, centre.y - 4, 20, 8)).contains(.walnut5))
        let m = LightMask.room(mac, lights: dark.effectiveLights, time: dark.timeOfDay)
        #expect(m.level(centre.x, centre.y) == 7 && m.tint(centre.x, centre.y) == .warm)
        #expect(m.level(pool.x + 6, centre.y) == 6)

        let roomLit = RoomState(time: WallTime(hour: 22, minute: 0))
        #expect(roomLit.timeOfDay.ambientLevel == 6)
        let m2 = LightMask.room(mac, lights: roomLit.effectiveLights, time: roomLit.timeOfDay)
        #expect(m2.level(centre.x, centre.y) == 0)
        let glow = RoomPlan.placements(mac, roomLit, only: RoomPlan.glowIDs)
        #expect(glow.count == 2 && glow.allSatisfy { $0.image.opaqueBounds() == .zero })
    }

    @Test("Lamp, switch, pen cup, clock and basket read at 1×")
    func spriteAffordances() {
        let on = inks(PropArt.lamp(on: true).image), off = inks(PropArt.lamp(on: false).image)
        #expect(on.contains(.walnut5) && !off.contains(.walnut5) && off.contains(.red1))
        let sOn = RoomArt.roomSwitch(on: true).image, sOff = RoomArt.roomSwitch(on: false).image
        #expect(sOn.pixels.indices.filter { sOn.pixels[$0] != sOff.pixels[$0] }.count >= 6)
        #expect(sOn.pixel(0, 5) == Ink.neutral5.color && sOn.pixel(4, 5) != RoomArt.wall.color)
        let cup = inks(PropArt.penCup().image)
        #expect(cup.isSuperset(of: [.walnut4, .red3, .oak5]))
        let clock = inks(RoomArt.clock(hour: 3, minute: 47).image)
        #expect(clock.contains(.neutral0) && clock.contains(.neutral3))
        #expect(inks(PropArt.wastebasketBack().image).isSuperset(of: [.neutral2, .neutral4]))
        #expect(checkerWindows(PropArt.wastebasketFront().image, in: ArtRect(0, 8, 32, 26)) == 0)
        #expect(inks(PropArt.brush().image).contains(.red3))
    }

    @Test("String lights: grey glass by day, lit with halos from dusk, spans sag differently")
    func stringLights() {
        let r = ArtRect(0, 0, 400, 14)
        let day = inks(RoomArt.stringLights(r, lit: false).image)
        #expect(day.contains(.neutral5) && !day.contains(.walnut5))
        #expect(inks(RoomArt.stringLights(r, lit: true).image).contains(.walnut4))
        #expect(!RoomArt.stringLightsLit(TimeOfDay(phase: .day, roomLightOn: false)))
        #expect(RoomArt.stringLightsLit(TimeOfDay(phase: .dusk, roomLightOn: true)))
        let hooks = RoomArt.stringLightHooks(in: r)
        let wire = RoomArt.stringLightWire(in: r)
        let depths = (0..<(hooks.count - 1)).map { s in (hooks[s]..<hooks[s + 1]).compactMap { wire[$0] }.max() ?? 0 }
        #expect(Set(depths).count > 1)
    }

    @Test("Tall walls end at a ceiling; short cords; medium walls hang the lights from a picture rail")
    func wallHeights() throws {
        let tall = LayoutSolver.solve(display: pixelGridDesignTable[8].display())
        let crown = try #require(tall.decor(.crown).first).rect
        #expect(tall.coreOrigin.y - crown.y <= LayoutSolver.maxWallAbove)
        #expect(tall.decor(.ceiling).first?.rect.maxY == crown.y)
        for d in tall.decor(.pendant) + tall.decor(.hangingPlant) {
            #expect(d.rect.y == crown.maxY && d.rect.h <= LayoutSolver.maxCord + 28, "\(d)")
        }
        let medium = LayoutSolver.solve(display: DisplayGeometry(widthPt: 1280, heightPt: 800, backingScale: 1, topInsetPt: 25))
        let rail = try #require(medium.decor(.rail).first).rect
        #expect(medium.decor(.stringLights).first?.rect.y == rail.maxY)
        #expect(!medium.decor(.painting).isEmpty)
    }

    @Test("Under the desk: plank-aligned shade without checker rows, a shaded baseboard, the rug in front")
    func underDesk() {
        let b = RoomArt.backdrop(mac)
        let desk = mac.rect(CoreLayout.deskTop)
        let under = ArtRect(desk.x, mac.y(CoreLayout.apron.maxY), desk.w, mac.y(CoreLayout.floorY) - mac.y(CoreLayout.apron.maxY))
        #expect(checkerWindows(b, in: under) == 0)
        let board = inks(b, in: ArtRect(desk.x + 20, mac.y(CoreLayout.apron.maxY), desk.w - 40, 4))
        #expect(board.isDisjoint(with: [.neutral8, .neutral9]))
        #expect(inks(b, in: ArtRect(mac.x(200), mac.wallBaseY + 1, 20, 4)).contains(.walnut1))
        // The rug is not shaded: its field is the plain red.
        #expect(b.pixel(mac.x(110), mac.y(300)) == Ink.red2.color)
    }
}
