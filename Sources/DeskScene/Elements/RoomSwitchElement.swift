import DeskCore
import SpriteKit

/// The room light switch on the wall (DESIGN §2.2 E12): a click toggles the room light in the model. In Lamp Only
/// that turns the room light back on and the room settles into Night; switching it off at night with the lamp on
/// is Lamp Only again (`LightsState.settled`). The toggle's position is drawn by the room from the state.
public final class RoomSwitchElement: DeskElement {
    public let id = "room.switch"
    public let root = SKNode()
    unowned let context: SceneContext
    let placed: () -> PlacedElement?

    init(context: SceneContext, placed: @escaping () -> PlacedElement?) {
        self.context = context
        self.placed = placed
    }

    public func layout(_ layout: SceneLayout) {}

    /// Whether the room light is on in the model.
    var isOn: Bool { context.state?.lights.roomLightOn ?? true }

    public func hitTest(_ p: ArtPoint) -> Hit? {
        placed()?.hitTest(p).map { Hit(element: id, part: $0.part, rect: $0.rect) }
    }

    public func hoverStyle(_ hit: Hit) -> HoverStyle {
        hit.part == nil ? RoomContent.silhouetteRing(placed()) : .standard
    }

    public func tooltip(_ hit: Hit) -> TooltipSpec? {
        TooltipSpec(title: "Room Light", detail: isOn ? "On" : "Off", anchor: hit.rect)
    }

    public func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        switch gesture {
        case .press, .cancelPress:
            return .handled
        case .click(_, _, count: 1):
            guard let s = context.state else { return .handled }
            context.dispatch(.lights(s.lights.withRoomLight(!s.lights.roomLightOn)))
            return .handled
        case .click:
            return .handled
        case .dragBegan, .scroll:
            return .pass
        }
    }

    public func menu(_ hit: Hit) -> MenuSpec? {
        context.state.map { MenuSpec(MenuSpec.lights($0)) }
    }

    public func accessibilityItems() -> [AXItem] {
        [AXItem(id: "room.switch", label: isOn ? "Turn Room Light Off" : "Turn Room Light On", role: .button,
                frame: context.layout.rect(CoreLayout.roomSwitch))]
    }
}
