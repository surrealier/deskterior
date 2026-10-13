import DeskCore
import SpriteKit
import Testing
@testable import DeskScene

/// Dark-token hit filtering (DESIGN §2.1 visibility matrix, E12, M10): any element's token hit where the light is
/// below level 3 is a silhouette — a faint outline on hover, no tooltip, and clicks, drags and menus do nothing —
/// and the monitor's and phone's glows follow their state.
@Suite("Dark-token hits and glows")
struct DarkHitTests {
    typealias F = SceneFixture

    /// An element that shows tokens wherever it is told (as drawers, piles and floor tokens will) and records what
    /// reaches it.
    final class StubTokens: DeskElement {
        let id = "stub"
        let root = SKNode()
        var tokens: [(key: TokenKey, rect: ArtRect)] = []
        var gestures: [Gesture] = []
        var hovers: [Hit?] = []

        func layout(_ layout: SceneLayout) {}
        func hitTest(_ p: ArtPoint) -> Hit? {
            tokens.first { $0.rect.contains(p) }.map { Hit(element: id, part: "token", rect: $0.rect, token: $0.key) }
        }
        func hover(_ hit: Hit?) -> Bool {
            hovers.append(hit)
            return true
        }
        func tooltip(_ hit: Hit) -> TooltipSpec? { TooltipSpec(title: "stub", anchor: hit.rect) }
        func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
            gestures.append(gesture)
            return .handled
        }
        func menu(_ hit: Hit) -> MenuSpec? { MenuSpec([MenuItem("open", "Open", .open([hit.token!]))]) }
    }

    /// Lamp Only at 22:00 with the stub in the wastebasket's hit-test slot: a token in the lamp's pool and one on the
    /// dark floor.
    static func setUp() throws -> (SceneStore, StubTokens, lit: SIMD2<Float>, dark: SIMD2<Float>) {
        var s = F.state()
        s.lights = .lampOnly
        let store = SceneStore(s, time: WallTime(hour: 22, minute: 0))
        let scene = store.scene
        scene.lightsMode = .lampOnly
        let layout = try #require(scene.layout)
        let stub = StubTokens()
        func token(_ core: ArtPoint) -> ArtRect { ArtRect(origin: layout.point(core) - ArtPoint(8, 8), size: ArtSize(16, 16)) }
        stub.tokens = [(F.key(101), token(ArtPoint(130, 205))), (F.key(102), token(ArtPoint(120, 290)))]
        try #require(scene.room).install([stub], inSlotOf: "wastebasket")
        return (store, stub, F.centre(stub.tokens[0].rect), F.centre(stub.tokens[1].rect))
    }

    @Test("A token in the dark: faint outline, no tooltip, and clicks, drags and right-clicks do nothing")
    func darkToken() throws {
        let (store, stub, _, dark) = try Self.setUp()
        let scene = store.scene
        let p = Pointer(scene: scene)
        #expect(!scene.isTokenLit(stub.tokens[1].rect))
        _ = p.event(.move, dark)
        p.frames(30)
        #expect(scene.hoveredHit?.part == "token.dark" && scene.hoveredHit?.token == nil)
        #expect(scene.tooltipShown == nil, "no name in the dark")
        #expect(stub.hovers.isEmpty, "the stub never hears of it")
        guard case let .image(ring, at)? = scene.room?.hovered.flatMap({ h in DarkTokenElement().hoverStyle(h) }) else {
            Issue.record("no faint outline")
            return
        }
        #expect(at == stub.tokens[1].rect.origin - ArtPoint(1, 1) && ring.size == ArtSize(18, 18))
        #expect(Set(ring.pixels.filter { $0.a != 0 }) == [Ink.neutral9.color], "drawn in label white, dimmed by the dark")

        p.click(dark)
        p.click(dark, count: 2)
        p.drag(dark, dark + SIMD2(30, 0))
        _ = p.event(.rightDown, dark, count: 1)
        #expect(stub.gestures.isEmpty)
        #expect(store.actions.isEmpty && store.requests.isEmpty && !scene.isDragging)
    }

    @Test("A token in the lamp's pool is an ordinary token: its element hovers, tooltips, clicks and menus")
    func litToken() throws {
        let (store, stub, lit, _) = try Self.setUp()
        let scene = store.scene
        let p = Pointer(scene: scene)
        #expect(scene.isTokenLit(stub.tokens[0].rect))
        _ = p.event(.move, lit)
        p.frames(30)
        #expect(scene.hoveredHit?.token == F.key(101) && scene.tooltipShown?.title == "stub")
        p.click(lit)
        #expect(stub.gestures.contains { if case .click = $0 { true } else { false } })
        _ = p.event(.rightDown, lit, count: 1)
        guard case let .menu(menu, _)? = store.requests.last else { Issue.record("no menu"); return }
        #expect(menu.item("open") != nil)
    }

    @Test("Light makes a dark token pickable again (room light on); the lamp off makes a lit one dark")
    func followsTheLight() throws {
        let (store, stub, lit, dark) = try Self.setUp()
        let scene = store.scene
        let p = Pointer(scene: scene)
        store.dispatch(.lights(store.state.lights.withRoomLight(true)))
        scene.lightsMode = store.state.lights.mode
        #expect(scene.roomState?.timeOfDay.ambientLevel == 6)
        _ = p.event(.move, dark)
        #expect(scene.hoveredHit?.token == F.key(102))
        store.dispatch(.lights(LightsState(mode: .night, room: false, lamp: false)))
        scene.lightsMode = store.state.lights.mode
        _ = p.event(.move, lit)
        #expect(scene.hoveredHit?.part == "token.dark")
        #expect(!scene.isTokenLit(stub.tokens[0].rect))
    }

    @Test("Screen tokens stay pickable in Lamp Only: the lit screen is its own light")
    func screenTokens() throws {
        let (store, _, _, _) = try Self.setUp()
        let scene = store.scene
        let p = Pointer(scene: scene)
        let screen = try #require(scene.screen)
        let r = try #require(screen.iconRect(of: F.key(1)))
        #expect(scene.isTokenLit(r))
        _ = p.event(.move, F.centre(r))
        #expect(screen.hovered == F.key(1))
    }

    @Test("The monitor's glow leaves with the CRT collapse (the glass glows on), and comes back with the bloom")
    func monitorGlow() throws {
        let (store, _, _, _) = try Self.setUp()
        let scene = store.scene
        let p = Pointer(scene: scene)
        let desk = scene.layout!.point(ArtPoint(264, 186))
        #expect(scene.lightLevel(at: desk) == 5)
        store.dispatch(.power(false))
        p.frames(2)
        #expect(scene.monitor?.machine?.phase == .poweringOff)
        #expect(scene.roomState?.effectiveLights.monitorOn == true && scene.roomState?.effectiveLights.monitorGlows == false)
        #expect(scene.lightLevel(at: desk) < 3)
        p.frames(60)
        #expect(scene.roomState?.effectiveLights.monitorOn == false)
        store.dispatch(.power(true))
        p.frames(2)
        #expect(scene.roomState?.effectiveLights.monitorGlows == true && scene.lightLevel(at: desk) == 5)
    }

    @Test("Reduce Motion: power off and on without the CRT; the glow follows at once")
    func reduceMotionCRT() throws {
        let (store, _, _, _) = try Self.setUp()
        let scene = store.scene
        scene.reduceMotion = true
        store.dispatch(.power(false))
        #expect(scene.monitor?.machine?.phase == .off && scene.roomState?.effectiveLights.monitorOn == false)
        store.dispatch(.power(true))
        #expect(scene.monitor?.machine?.phase == .on && scene.roomState?.effectiveLights.monitorGlows == true)
    }

    @Test("A face-down phone casts no glow")
    func phoneGlow() throws {
        let (store, _, _, _) = try Self.setUp()
        let scene = store.scene
        let glow = scene.layout!.point(ArtPoint(392, 170))
        #expect(scene.lightLevel(at: glow) >= 4)
        store.dispatch(.phoneFlip)
        #expect(store.state.phone.faceDown && scene.roomState?.effectiveLights.phoneFaceUp == false)
        #expect(scene.lightLevel(at: glow) == 1)
    }
}
