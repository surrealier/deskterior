import DeskCore
import SpriteKit

/// The desk lamp (DESIGN §2.2 E12): a click on it (the base switch, or anywhere on the lamp) turns it on or off at
/// once in the model, while the bulb flickers new–old–new for three 12 fps frames before it settles (none with
/// Reduce Motion). Its pool of light is fixed (`CoreLayout.lampPool`); the room draws the lamp, its bulb and the
/// pool from the state, so this element only answers hits, the flicker and the Lights menu.
public final class LampElement: DeskElement {
    public let id = "lamp"
    public let root = SKNode()
    unowned let context: SceneContext
    /// The room's placed lamp (sprites and alpha hit tests).
    let placed: () -> PlacedElement?
    /// The flicker in progress and the state it ends on.
    private(set) var flicker: (animation: DecorAnimation, on: Bool)?

    static let flickerFrames = 3

    init(context: SceneContext, placed: @escaping () -> PlacedElement?) {
        self.context = context
        self.placed = placed
    }

    public func layout(_ layout: SceneLayout) {}

    /// Whether the lamp is on in the model (Lamp Only keeps it on).
    var isOn: Bool { context.state?.lights.lampLit ?? true }

    public func hitTest(_ p: ArtPoint) -> Hit? {
        placed()?.hitTest(p).map { Hit(element: id, part: $0.part, rect: $0.rect) }
    }

    public func hoverStyle(_ hit: Hit) -> HoverStyle {
        hit.part == nil ? RoomContent.silhouetteRing(placed()) : .standard
    }

    public func tooltip(_ hit: Hit) -> TooltipSpec? {
        TooltipSpec(title: "Desk Lamp", detail: isOn ? "On" : "Off", anchor: hit.rect)
    }

    public func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        switch gesture {
        case .press, .cancelPress:
            return .handled
        case .click(_, _, count: 1):
            toggle()
            return .handled
        case .click:
            return .handled
        case .dragBegan, .scroll:
            return .pass
        }
    }

    /// Switches the lamp: the model first (zero latency), then the flicker.
    func toggle() {
        guard let s = context.state else { return }
        let on = !s.lights.lampLit
        if !context.reduceMotion {
            flicker = (DecorAnimation(count: Self.flickerFrames), on)
            context.lightOverrides.lampLit = Self.frame(0, endingOn: on)
        }
        context.dispatch(.lights(s.lights.withLamp(on)))
    }

    /// Flicker frame `i`: the new state, the old one, the new one.
    static func frame(_ i: Int, endingOn on: Bool) -> Bool {
        i % 2 == 0 ? on : !on
    }

    public func menu(_ hit: Hit) -> MenuSpec? {
        context.state.map { MenuSpec(MenuSpec.lights($0)) }
    }

    public func accessibilityItems() -> [AXItem] {
        [AXItem(id: "lamp.switch", label: isOn ? "Turn Desk Lamp Off" : "Turn Desk Lamp On", role: .button,
                frame: context.layout.rect(CoreLayout.lampSwitch).insetBy(-2, -2))]
    }

    public var needsFrames: Bool { flicker != nil }

    public func step(_ dt: Double) {
        guard var f = flicker else { return }
        f.animation.advance(dt)
        if f.animation.isFinished {
            settle()
            return
        }
        flicker = f
        context.lightOverrides.lampLit = Self.frame(f.animation.index, endingOn: f.on)
    }

    public func settle() {
        flicker = nil
        context.lightOverrides.lampLit = nil
    }
}
