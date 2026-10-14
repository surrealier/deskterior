import DeskCore
import Foundation
import Testing
@testable import DeskScene

/// M10 review fixes: the hover and the selection follow the light under a resting pointer, Reduce Motion never
/// shakes, a long clock preview springs back the short way, a preview past midnight turns the calendar, a dark
/// token's menu is empty everywhere, and hover rings show in the dark.
@Suite("Lighting review fixes")
struct LightingReviewTests {
    typealias F = SceneFixture

    @Test("The lamp going off under a resting pointer: the token is a dark outline at once, its name gone")
    func hoverFollowsLightOff() throws {
        let (store, stub, lit, _) = try DarkHitTests.setUp()
        let scene = store.scene
        let p = Pointer(scene: scene)
        _ = p.event(.move, lit)
        p.frames(40)
        #expect(scene.hoveredHit?.token == F.key(101) && scene.tooltipShown?.title == "stub")
        store.dispatch(.lights(store.state.lights.withLamp(false)))
        scene.lightsMode = store.state.lights.mode
        p.frames(40)
        #expect(!scene.isTokenLit(stub.tokens[0].rect))
        #expect(scene.hoveredHit?.part == "token.dark", "the hover follows the light")
        #expect(scene.tooltipShown == nil, "no name in the dark")
    }

    @Test("The room light coming on under a resting pointer: the dark token is hovered as itself at once")
    func hoverFollowsLightOn() throws {
        let (store, _, _, dark) = try DarkHitTests.setUp()
        let scene = store.scene
        let p = Pointer(scene: scene)
        _ = p.event(.move, dark)
        p.frames(40)
        #expect(scene.hoveredHit?.part == "token.dark")
        store.dispatch(.lights(store.state.lights.withRoomLight(true)))
        scene.lightsMode = store.state.lights.mode
        #expect(scene.hoveredHit?.token == F.key(102))
        p.frames(40)
        #expect(scene.tooltipShown?.title == "stub")
    }

    @Test("A flicker or a clock preview relights under a resting pointer too")
    func hoverFollowsOverrides() throws {
        let (store, stub, lit, _) = try DarkHitTests.setUp()
        let scene = store.scene
        let p = Pointer(scene: scene)
        _ = p.event(.move, lit)
        p.click(F.centre(scene.layout!.rect(CoreLayout.lampSwitch)))
        scene.lightsMode = store.state.lights.mode
        _ = p.event(.move, lit)
        // Mid-flicker the bulb is on again for a frame: the token under the pointer is lit, then dark again.
        var parts: [String?] = []
        for _ in 0..<20 {
            p.frames(1)
            parts.append(scene.hoveredHit?.part)
        }
        #expect(parts.contains("token") && parts.last == "token.dark", "\(parts)")
        #expect(!scene.isTokenLit(stub.tokens[0].rect))
    }

    @Test("Selected tokens the light leaves are let go, so keys never act on what cannot be seen")
    func selectionFollowsLight() throws {
        let (store, _, _, _) = try DarkHitTests.setUp()
        let scene = store.scene
        let p = Pointer(scene: scene)
        let sel = try #require(scene.selection)
        sel.set([F.key(101), F.key(102), F.key(1)])
        p.frames(2)
        // The token in the dark goes at once; the one in the lamp's pool and the screen's stay.
        #expect(sel.keys == [F.key(101), F.key(1)])
        store.dispatch(.lights(store.state.lights.withLamp(false)))
        scene.lightsMode = store.state.lights.mode
        p.frames(30)
        #expect(sel.keys == [F.key(1)], "the lamp off: only the lit screen's token stays")
        _ = scene.handleKey(.open)
        #expect(store.actions.last == "\(DeskAction.requestOpen([F.key(1)]))")
    }

    @Test("Reduce Motion: no screen shake (a bonk still counts)")
    func noShake() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let room = try #require(scene.room)
        room.context.shake(frames: 2)
        #expect(scene.shake != .zero)
        room.forceRest()
        scene.reduceMotion = true
        room.context.shake(frames: 2)
        #expect(scene.shake == .zero && !scene.needsFrames)
    }

    @Test("Reduce Motion's CRT is a 2-frame fade through dimmer palette colours of the picture")
    func crtFade() {
        let picture = PixelBuffer(width: 4, height: 1, pixels: [Ink.neutral9, .blue4, .walnut4, .green3].map(\.color))
        let off = MonitorArt.fadeFrames(picture, poweringOn: false)
        #expect(off.count == 2 && MonitorArt.fadeFrames(picture, poweringOn: true) == off.reversed())
        func lightness(_ b: PixelBuffer) -> Double { b.pixels.map { OKLab($0).L }.reduce(0, +) }
        #expect(lightness(picture) > lightness(off[0]) && lightness(off[0]) > lightness(off[1]))
        #expect(off.allSatisfy { $0.pixels.allSatisfy { Apollo.index(of: $0) != nil } })
    }

    @Test("A 12-hour preview springs back the short way: under half a turn, no strobe, no flash through the phases")
    func longPreviewSpring() throws {
        let store = SceneStore(F.state(), time: WallTime(hour: 8, minute: 30))
        let scene = store.scene
        let clock = try #require(scene.roomElement("clock") as? ClockElement)
        let overrides = try #require(scene.lightOverrides)
        _ = clock.beginPreview()
        clock.turn(by: 12 * 60 + 10)
        #expect(overrides.previewTime == WallTime(hour: 20, minute: 40))
        clock.release()
        // The whole hours drop at once: the hands are 10 minutes ahead, the light with them.
        #expect(overrides.previewTime == WallTime(hour: 8, minute: 40))
        var minutes: [Int] = []
        var phases: [DayPhase] = []
        for _ in 0..<40 {
            scene.step(1.0 / 60)
            guard let t = scene.roomState?.time else { continue }
            minutes.append(t.minuteOfDay - (8 * 60 + 30))
            if let ph = scene.roomState?.timeOfDay.phase, phases.last != ph { phases.append(ph) }
        }
        #expect(phases == [.day], "\(phases)")
        // At 60 fps the minute hand never turns more than a few minutes a frame (no wagon-wheel strobe).
        let steps = zip(minutes, minutes.dropFirst()).map { abs($1 - $0) }
        #expect(steps.allSatisfy { $0 <= 5 }, "\(minutes)")
        #expect((minutes.min() ?? 0) >= -2, "overshoots by a minute or two at most: \(minutes)")
        #expect(minutes.last == 0 && overrides.previewTime == nil && !scene.needsFrames)
        #expect(ClockElement.shortWay(12 * 60 + 40) == -20 && ClockElement.shortWay(-95) == 25)
    }

    @Test("A preview past midnight turns the calendar's date, both ways")
    func previewTurnsTheDate() throws {
        let store = SceneStore(F.state(), time: WallTime(year: 2026, month: 12, day: 31, hour: 23, minute: 50))
        let scene = store.scene
        let clock = try #require(scene.roomElement("clock") as? ClockElement)
        _ = clock.beginPreview()
        clock.turn(by: 21)
        #expect(scene.roomState?.time == WallTime(year: 2027, month: 1, day: 1, hour: 0, minute: 11))
        clock.turn(by: -21 - 24 * 60)
        #expect(scene.roomState?.time == WallTime(year: 2026, month: 12, day: 30, hour: 23, minute: 50))
        clock.release()
        #expect(scene.roomState?.time == WallTime(year: 2026, month: 12, day: 31, hour: 23, minute: 50))
        #expect(ClockElement.date(of: WallTime(year: 2028, month: 3, day: 1, hour: 0, minute: 0), plusDays: -1,
                                  hour: 23, minute: 59) == WallTime(year: 2028, month: 2, day: 29, hour: 23, minute: 59))
    }

    @Test("contextMenu(at:) over a dark token is empty, as a right-click there shows nothing")
    func darkTokenMenu() throws {
        let (store, _, lit, dark) = try DarkHitTests.setUp()
        let scene = store.scene
        #expect(scene.contextMenu(at: ArtPoint(Int(dark.x), Int(dark.y))).items.isEmpty)
        #expect(scene.contextMenu(at: ArtPoint(Int(lit.x), Int(lit.y))).item("open") != nil)
    }

    @Test("Hover rings show in the dark: lit full for the room switch, faintly for a dark token's outline")
    func ringsLitInTheDark() throws {
        let (store, _, _, dark) = try DarkHitTests.setUp()
        let scene = store.scene
        let p = Pointer(scene: scene)
        let room = try #require(scene.room)
        func ringLevels() -> Set<Int> {
            guard let ring = room.hoverRing else { return [] }
            let mask = scene.lighting.mask, w = scene.layout!.canvas.w
            var out = Set<Int>()
            for y in 0..<ring.image.height {
                for x in 0..<ring.image.width where ring.image.pixel(x, y).a != 0 {
                    out.insert(Int(mask[(ring.origin.y + y) * w + ring.origin.x + x] & 7))
                }
            }
            return out
        }
        _ = p.event(.move, F.centre(scene.layout!.rect(CoreLayout.roomSwitch)))
        #expect(scene.hoveredHit?.element == "room.switch")
        #expect(ringLevels() == [7], "the blue ring keeps its colour at ambient 1")
        _ = p.event(.move, dark)
        #expect(scene.hoveredHit?.part == "token.dark")
        #expect(ringLevels() == [DarkTokenElement.ringLevel], "a faint outline, not a full white one")
        let faint = LightRamp.shared.mapColor(DarkTokenElement.ink.color, level: DarkTokenElement.ringLevel, tint: .cool)
        let wall = LightRamp.shared.mapColor(DarkTokenElement.ink.color, level: 1, tint: .cool)
        #expect(faint != wall && OKLab(faint).L > OKLab(wall).L + 0.1)
        let bare = scene.layout!.point(ArtPoint(300, 4))
        _ = p.event(.move, SIMD2(Float(bare.x) + 0.5, Float(bare.y) + 0.5))
        #expect(room.hoverRing == nil && room.litOverlay.ring == nil)

        // By day the ring needs no light of its own (nothing to push).
        let day = SceneStore(F.state()).scene
        let q = Pointer(scene: day)
        _ = q.event(.move, F.centre(day.layout!.rect(CoreLayout.roomSwitch)))
        #expect(day.room?.hoverRing != nil && day.room?.litOverlay.ring == nil)
    }
}
