import DeskCore
import SpriteKit

/// The keyboard (DESIGN §2.2 E14): clicking a key presses it 1 px for two 12 fps frames. It never reflects real
/// typing. The room keeps drawing the keyboard (wherever it is placed); a pressed frame covers it meanwhile.
public final class KeyboardElement: DeskElement {
    public let id = "keyboard"
    public let root = SKNode()
    unowned let context: SceneContext
    let placed: () -> PlacedElement?
    private let pressedNode = SKSpriteNode()
    /// The key held down and for how long.
    private(set) var pressed: (row: Int, col: Int, animation: DecorAnimation)?

    static let pressFrames = 2

    /// The key drawn pressed now ("row,col"), if any.
    public var pressedKey: (row: Int, col: Int)? { pressed.map { ($0.row, $0.col) } }

    init(context: SceneContext, placed: @escaping () -> PlacedElement?) {
        self.context = context
        self.placed = placed
        pressedNode.isHidden = true
        root.addChild(pressedNode)
    }

    public func layout(_ layout: SceneLayout) {}

    /// Where the room draws the keyboard (canvas px).
    var origin: ArtPoint? { placed()?.placements.first { $0.id == id }?.origin }

    public func hitTest(_ p: ArtPoint) -> Hit? {
        placed()?.hitTest(p).map { Hit(element: id, part: $0.part, rect: $0.rect) }
    }

    public func hoverStyle(_ hit: Hit) -> HoverStyle {
        RoomContent.silhouetteRing(placed())
    }

    public func tooltip(_ hit: Hit) -> TooltipSpec? {
        TooltipSpec(title: "Keyboard", anchor: hit.rect)
    }

    public func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        switch gesture {
        case .press, .cancelPress:
            return .handled
        case let .click(p, _, _):
            pressKey(at: ArtPoint(Int(p.x.rounded(.down)), Int(p.y.rounded(.down))))
            return .handled
        case .dragBegan, .scroll:
            return .pass
        }
    }

    /// Presses the key under canvas pixel `p`; false between keys or off the keyboard.
    @discardableResult
    func pressKey(at p: ArtPoint) -> Bool {
        guard let o = origin, let key = PropArt.keyboardKey(at: ArtPoint(p.x - o.x, p.y - o.y)) else { return false }
        pressed = (key.row, key.col, DecorAnimation(count: Self.pressFrames))
        let image = PropArt.keyboard(pressed: key).image
        pressedNode.texture = TextureFactory.texture(image)
        context.space.place(pressedNode, at: ArtRect(origin: o, size: image.size))
        pressedNode.zPosition = context.placementZ(id) + 0.5
        pressedNode.isHidden = false
        placed()?.root.isHidden = true
        return true
    }

    public var needsFrames: Bool { pressed != nil }

    public func step(_ dt: Double) {
        guard var p = pressed else { return }
        p.animation.advance(dt)
        if p.animation.isFinished { settle() } else { pressed = p }
    }

    public func settle() {
        guard pressed != nil else { return }
        pressed = nil
        pressedNode.isHidden = true
        placed()?.root.isHidden = false
    }
}
