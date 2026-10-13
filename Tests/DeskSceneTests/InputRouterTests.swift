import DeskCore
import Testing
@testable import DeskScene

/// A router target over stub elements, recording what the router asks for.
final class StubTarget: GestureTarget {
    var elements: [StubElement] = []
    var hover: Hit?
    var tooltip: TooltipSpec?
    var unhandled: [Gesture] = []
    var menus: [(SIMD2<Float>, String?)] = []
    var keys: [KeyCommand] = []
    var settled: [any DragController] = []

    func target(at p: ArtPoint) -> (hit: Hit, element: any DeskElement)? {
        for e in elements { if let h = e.hitTest(p) { return (h, e) } }
        return nil
    }

    func setHover(_ hit: Hit?, element: (any DeskElement)?) -> Bool {
        guard hit != hover else { return false }
        hover = hit
        return true
    }

    func setTooltip(_ spec: TooltipSpec?) -> Bool {
        guard spec != tooltip else { return false }
        tooltip = spec
        return true
    }

    func unhandled(_ gesture: Gesture) -> Bool {
        unhandled.append(gesture)
        return false
    }

    func menu(at p: SIMD2<Float>, hit: Hit?, element: (any DeskElement)?) { menus.append((p, hit?.element)) }

    func key(_ command: KeyCommand) -> Bool {
        keys.append(command)
        return true
    }

    func settle(_ drag: any DragController) { settled.append(drag) }
}

/// A drag controller that records its life.
final class StubDrag: DragController {
    var moves: [SIMD2<Float>] = []
    var ended: (SIMD2<Float>, SIMD2<Float>)?
    var wasCancelled = false
    var isFinished = false
    var needsFrames: Bool { !isFinished }
    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers) { moves.append(p) }
    func ended(at p: SIMD2<Float>, velocity: SIMD2<Float>, mods: InputEvent.Modifiers) { ended = (p, velocity) }
    func cancelled() { wasCancelled = true }
    func step(_ dt: Double) {}
}

@Suite("InputRouter")
struct InputRouterTests {
    let button = StubElement("button", ArtRect(10, 10, 20, 20))
    let target = StubTarget()

    init() {
        target.elements = [button]
    }

    func ev(_ kind: InputEvent.Kind, _ x: Float, _ y: Float, t: Double, mods: InputEvent.Modifiers = [], count: Int = 0,
            scroll: SIMD2<Float> = .zero) -> InputEvent {
        InputEvent(kind, art: SIMD2(x, y), mods: mods, clickCount: count, scroll: scroll, t: t)
    }

    @Test("Press then release in place is a click with the press's modifiers and count")
    func click() {
        let r = InputRouter(target: target)
        r.handle(ev(.down, 15, 15, t: 1, mods: .command, count: 2))
        r.handle(ev(.up, 15.5, 15, t: 1.1, count: 2))
        #expect(button.gestures == [.press(SIMD2(15, 15), .command), .click(SIMD2(15.5, 15), .command, count: 2)])
    }

    @Test("A drag starts past 3 art px; an element that passes gets cancelPress and no click")
    func dragThreshold() {
        let r = InputRouter(target: target)
        button.response = .pass
        r.handle(ev(.down, 15, 15, t: 1, count: 1))
        r.handle(ev(.drag, 17.9, 15, t: 1.1))
        #expect(button.gestures == [.press(SIMD2(15, 15), [])])
        r.handle(ev(.drag, 18.5, 15, t: 1.2))
        #expect(button.gestures.dropFirst() == [.dragBegan(from: SIMD2(15, 15), at: SIMD2(18.5, 15), []), .cancelPress])
        r.handle(ev(.up, 18.5, 15, t: 1.3))
        #expect(button.gestures.count == 3 && target.unhandled.isEmpty)
    }

    @Test("A drag controller gets every move, the release velocity (clamped) and is handed over to settle")
    func dragController() {
        let r = InputRouter(target: target)
        let drag = StubDrag()
        button.response = .drag(drag)
        r.handle(ev(.down, 15, 15, t: 1, count: 1))
        r.handle(ev(.drag, 25, 15, t: 1.01))
        r.handle(ev(.drag, 35, 15, t: 1.02))
        #expect(drag.moves == [SIMD2(35, 15)])
        r.handle(ev(.up, 45, 15, t: 1.03))
        let (p, v) = try! #require(drag.ended)
        #expect(p == SIMD2(45, 15) && v.x > 0 && v.x <= InputRouter.maxVelocity + 0.01)
        #expect(target.settled.count == 1 && r.drag == nil)
    }

    @Test("Esc and right-click cancel a drag")
    func cancel() {
        let r = InputRouter(target: target)
        let drag = StubDrag()
        button.response = .drag(drag)
        r.handle(ev(.down, 15, 15, t: 1, count: 1))
        r.handle(ev(.drag, 25, 15, t: 1.1))
        #expect(r.key(.escape) && drag.wasCancelled && r.drag == nil && target.keys.isEmpty)
        #expect(r.key(.escape) && target.keys == [.escape])
        let drag2 = StubDrag()
        button.response = .drag(drag2)
        r.handle(ev(.down, 15, 15, t: 2, count: 1))
        r.handle(ev(.drag, 25, 15, t: 2.1))
        r.handle(ev(.rightDown, 25, 15, t: 2.2, count: 1))
        #expect(drag2.wasCancelled && target.menus.count == 1 && target.menus[0].1 == "button")
    }

    @Test("Hover changes report once; the tooltip waits 250 ms; a press hides it")
    func hoverTooltip() {
        let r = InputRouter(target: target)
        button.tip = TooltipSpec(title: "Button", anchor: button.rect)
        #expect(r.handle(ev(.move, 12, 12, t: 1)))
        #expect(!r.handle(ev(.move, 13, 12, t: 1.05)))
        #expect(r.nextDeadline == 1.25 && target.tooltip == nil)
        #expect(!r.advance(to: 1.2) && r.advance(to: 1.25) && target.tooltip?.title == "Button")
        #expect(r.handle(ev(.down, 13, 12, t: 2, count: 1)) && target.tooltip == nil)
        r.handle(ev(.up, 13, 12, t: 2.1, count: 1))
        #expect(r.handle(ev(.move, 50, 50, t: 3)) && target.hover == nil && r.nextDeadline == nil)
        #expect(button.hovers.last! == nil)
    }

    @Test("Clicks nobody takes go to the bare desk; scroll goes to the element under the pointer")
    func fallbacks() {
        let r = InputRouter(target: target)
        r.handle(ev(.down, 50, 50, t: 1, count: 1))
        r.handle(ev(.up, 50, 50, t: 1.1, count: 1))
        #expect(target.unhandled == [.click(SIMD2(50, 50), [], count: 1)])
        #expect(r.handle(ev(.scroll, 15, 15, t: 2, scroll: SIMD2(-5, 0))))
        #expect(button.gestures.last == .scroll(SIMD2(15, 15), delta: SIMD2(-5, 0), []))
        #expect(!r.handle(ev(.scroll, 50, 50, t: 2, scroll: SIMD2(-5, 0))))
        #expect(r.handle(ev(.key, 0, 0, t: 3)) == false, "key code 0 without ⌘ is no command")
    }
}
