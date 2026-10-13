import DeskCore
import Testing
@testable import DeskScene

/// E12 and E14 (M10): the lamp's switch with its flicker, the wall switch, the Lights menu on both, the keyboard's
/// key press and the plant's jiggle, and what Reduce Motion skips.
@Suite("Lamp, room switch, keyboard, plant")
struct LampTests {
    typealias F = SceneFixture

    /// A desk at 22:00 in Lamp Only (as the app shows it: the scene follows the model's mode).
    static func lampOnlyStore() -> SceneStore {
        var s = F.state()
        s.lights = .lampOnly
        let store = SceneStore(s, time: WallTime(hour: 22, minute: 0))
        store.scene.lightsMode = .lampOnly
        return store
    }

    static func centre(_ scene: DeskScene, core: ArtRect) -> SIMD2<Float> {
        F.centre(scene.layout!.rect(core))
    }

    /// The pool's light at its centre now.
    static func poolLevel(_ scene: DeskScene) -> Int {
        let pool = scene.layout!.rect(CoreLayout.lampPool)
        return scene.lightLevel(at: ArtPoint(pool.midX, pool.midY))
    }

    @Test("The lamp's switch: off at once in the model, the bulb flickers new–old–new, then stays off")
    func lampFlicker() throws {
        let store = Self.lampOnlyStore()
        let scene = store.scene
        let p = Pointer(scene: scene)
        #expect(Self.poolLevel(scene) == 7)
        p.click(Self.centre(scene, core: CoreLayout.lampSwitch))
        #expect(store.state.lights == LightsState(mode: .night, room: false, lamp: false))
        scene.lightsMode = store.state.lights.mode
        let overrides = try #require(scene.lightOverrides)
        var shown: [Bool?] = [overrides.lampLit]
        var pool: [Int] = [Self.poolLevel(scene)]
        for _ in 0..<20 {
            p.frames(1)
            shown.append(overrides.lampLit)
            pool.append(Self.poolLevel(scene))
        }
        // Three 12 fps frames (5 display frames each): off, on, off; then the model's off.
        #expect(Array(shown.prefix(15)) == [false, false, false, false, false, true, true, true, true, true, false, false,
                                             false, false, false])
        #expect(shown.last == .some(nil))
        #expect(pool[5] == 7 && pool[0] == 1 && pool.last == 1, "the pool flickers with the bulb: \(pool)")
        #expect(!scene.needsFrames)
        // On again: Lamp Only (emergent).
        p.click(Self.centre(scene, core: CoreLayout.lampSwitch))
        #expect(store.state.lights == .lampOnly)
    }

    @Test("Reduce Motion: the lamp switches without a flicker; the plant does not jiggle")
    func reduceMotion() throws {
        let store = Self.lampOnlyStore()
        let scene = store.scene
        scene.reduceMotion = true
        let p = Pointer(scene: scene)
        p.click(Self.centre(scene, core: CoreLayout.lampSwitch))
        #expect(store.state.lights.lamp == false)
        #expect(scene.lightOverrides?.lampLit == nil && !scene.needsFrames)
        p.click(Self.centre(scene, core: CoreLayout.plant))
        #expect((scene.roomElement("plant") as? PlantElement)?.isJiggling == false && !scene.needsFrames)
    }

    @Test("The wall switch: room light on from Lamp Only is Night (warm, ambient 6); off again is Lamp Only")
    func roomSwitch() {
        let store = Self.lampOnlyStore()
        let scene = store.scene
        let p = Pointer(scene: scene)
        let sw = Self.centre(scene, core: CoreLayout.roomSwitch)
        p.click(sw)
        #expect(store.state.lights == LightsState(mode: .night, room: true, lamp: true))
        scene.lightsMode = store.state.lights.mode
        #expect(scene.roomState?.timeOfDay.ambientLevel == 6 && scene.roomState?.timeOfDay.ambientTint == .warm)
        #expect(scene.roomState?.effectiveLights.roomLightOn == true)
        p.click(sw)
        #expect(store.state.lights == .lampOnly)
        // Hover: the switch's ring and a tooltip that says what it is.
        _ = p.event(.move, sw)
        p.frames(20)
        #expect(scene.tooltipShown?.title == "Room Light" && scene.tooltipShown?.detail == "Off")
    }

    @Test("Right-click on the lamp or the switch: the Lights menu, whose items work")
    func lightsMenu() throws {
        let store = Self.lampOnlyStore()
        let scene = store.scene
        for core in [CoreLayout.lampSwitch, CoreLayout.roomSwitch] {
            let at = Self.centre(scene, core: core)
            let menu = scene.contextMenu(at: ArtPoint(Int(at.x), Int(at.y)))
            #expect(menu.item("lights.lamp")?.isChecked == true && menu.item("lights.room")?.isEnabled == true)
            #expect(menu.item("takeEverythingOut") == nil, "not the desk menu")
        }
    }

    @Test("A key presses 1 px for two 12 fps frames and never reflects typing; a gap presses nothing")
    func keyboard() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let kb = try #require(scene.roomElement("keyboard") as? KeyboardElement)
        let origin = scene.layout!.point(CoreLayout.keyboard.origin)
        let space = try #require(PropArt.keyboardKeys.first { $0.row == 3 && $0.col == 3 })
        p.click(F.centre(space.rect.offsetBy(origin.x, origin.y)))
        #expect(kb.pressedKey.map { $0.row == 3 && $0.col == 3 } == true)
        #expect(scene.needsFrames)
        p.frames(9)
        #expect(kb.pressedKey != nil)
        p.frames(2)
        #expect(kb.pressedKey == nil && !scene.needsFrames)
        // Below the caps (the plate's front edge) is not a key.
        p.click(SIMD2(Float(origin.x + 48) + 0.5, Float(origin.y + 13) + 0.5))
        #expect(kb.pressedKey == nil)
        #expect(store.actions.isEmpty, "the keyboard changes nothing in the model")
    }

    @Test("A poke jiggles the plant for four 12 fps frames")
    func plant() throws {
        let store = SceneStore(F.state())
        let scene = store.scene
        let p = Pointer(scene: scene)
        let plant = try #require(scene.roomElement("plant") as? PlantElement)
        p.click(Self.centre(scene, core: CoreLayout.plant))
        #expect(plant.isJiggling)
        p.frames(19)
        #expect(plant.isJiggling)
        p.frames(2)
        #expect(!plant.isJiggling && !scene.needsFrames)
        #expect(store.actions.isEmpty)
    }
}
