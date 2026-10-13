import DeskCore
import SpriteKit
import Testing
@testable import DeskScene

/// An element with a fixed rect and a fixed drop verdict.
final class StubElement: DeskElement {
    let id: String
    let root = SKNode()
    let rect: ArtRect
    let verdict: DropVerdict?
    var gestures: [Gesture] = []
    var response: GestureResponse = .handled
    var tip: TooltipSpec?
    var hovers: [Hit?] = []

    init(_ id: String, _ rect: ArtRect, verdict: DropVerdict? = nil) {
        self.id = id
        self.rect = rect
        self.verdict = verdict
    }

    func layout(_ layout: SceneLayout) {}
    func hitTest(_ p: ArtPoint) -> Hit? { rect.contains(p) ? Hit(element: id, part: "\(id).body", rect: rect) : nil }
    func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? { rect.contains(p) ? verdict : nil }
    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        gestures.append(gesture)
        return response
    }
    func tooltip(_ hit: Hit) -> TooltipSpec? { tip }
    func hover(_ hit: Hit?) -> Bool {
        hovers.append(hit)
        return false
    }
}

@Suite("DropResolver")
struct DropResolverTests {
    typealias F = SceneFixture
    let k = [SceneFixture.key(1)]

    @Test("The first element front to back with a verdict wins; none means spring back")
    func order() {
        let front = StubElement("front", ArtRect(0, 0, 10, 10), verdict: .bonk(nil))
        let silent = StubElement("silent", ArtRect(0, 0, 40, 40))
        let back = StubElement("back", ArtRect(0, 0, 40, 40), verdict: .accept(.floor(x: 3)))
        let elements: [any DeskElement] = [front, silent, back]
        #expect(DropResolver.resolve(k, at: ArtPoint(5, 5), elements: elements) == .init(verdict: .bonk(nil), element: "front"))
        #expect(DropResolver.resolve(k, at: ArtPoint(20, 20), elements: elements) == .init(verdict: .accept(.floor(x: 3)), element: "back"))
        #expect(DropResolver.resolve(k, at: ArtPoint(50, 50), elements: elements) == nil)
        #expect(DropResolver.resolve([], at: ArtPoint(5, 5), elements: elements) == nil)
    }

    @Test("In the room: the screen takes drops while it shows the desktop and bonks otherwise; drives bonk")
    func room() throws {
        var s = F.state()
        let scene = F.scene(s)
        let room = try #require(scene.room)
        let screen = try #require(scene.screen)
        let cell = screen.cellRect(4, 3).center
        #expect(DropResolver.resolve(k, at: cell, elements: room.routing)?.verdict == .accept(.screen(page: 0, col: 4, row: 3)))
        // Gutters snap to the nearest cell; the bezel takes nothing.
        let glass = try #require(scene.layout).rect(CoreLayout.screen)
        #expect(DropResolver.resolve(k, at: ArtPoint(glass.minX, glass.minY), elements: room.routing)?.verdict
            == .accept(.screen(page: 0, col: 0, row: 0)))
        #expect(DropResolver.resolve(k, at: ArtPoint(glass.minX - 3, glass.midY), elements: room.routing) == nil)
        let hub = try #require(scene.layout?.anchors["hub"]).center
        #expect(DropResolver.resolve(k, at: hub, elements: room.routing)?.verdict == .bonk(.drivesReadOnly))
        s.monitor.power = .off
        scene.apply(s)
        #expect(DropResolver.resolve(k, at: cell, elements: room.routing)?.verdict == .bonk(nil))
        s.monitor.power = .on
        s.monitor.av = true
        scene.apply(s)
        #expect(DropResolver.resolve(k, at: cell, elements: room.routing)?.verdict == .bonk(nil))
    }
}
