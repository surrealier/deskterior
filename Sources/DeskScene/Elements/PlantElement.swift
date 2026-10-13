import DeskCore
import SpriteKit

/// The snake plant (DESIGN §2.2 E14): poked (clicked), its blades jiggle for four 12 fps frames
/// (`PropArt.plantJiggle`); with Reduce Motion it stays still. Decor otherwise.
public final class PlantElement: DeskElement {
    public let id = "plant"
    public let root = SKNode()
    unowned let context: SceneContext
    let placed: () -> PlacedElement?
    private let jiggleNode = SKSpriteNode()
    /// The jiggle in progress.
    private(set) var jiggle: DecorAnimation?
    private var shownFrame = -1

    static let jiggleFrames = 4

    /// True while the plant jiggles.
    public var isJiggling: Bool { jiggle != nil }

    init(context: SceneContext, placed: @escaping () -> PlacedElement?) {
        self.context = context
        self.placed = placed
        jiggleNode.isHidden = true
        root.addChild(jiggleNode)
    }

    public func layout(_ layout: SceneLayout) {}

    public func hitTest(_ p: ArtPoint) -> Hit? {
        placed()?.hitTest(p).map { Hit(element: id, part: $0.part, rect: $0.rect) }
    }

    public func hoverStyle(_ hit: Hit) -> HoverStyle {
        RoomContent.silhouetteRing(placed())
    }

    public func tooltip(_ hit: Hit) -> TooltipSpec? {
        TooltipSpec(title: "Plant", anchor: hit.rect)
    }

    public func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        switch gesture {
        case .press, .cancelPress:
            return .handled
        case .click:
            poke()
            return .handled
        case .dragBegan, .scroll:
            return .pass
        }
    }

    /// Starts the jiggle (again, if one is running); nothing with Reduce Motion.
    func poke() {
        guard !context.reduceMotion else { return }
        jiggle = DecorAnimation(count: Self.jiggleFrames)
        shownFrame = -1
        show(0)
    }

    private func show(_ frame: Int) {
        guard frame != shownFrame, let pl = placed(), let origin = pl.placements.first(where: { $0.id == id })?.origin else { return }
        shownFrame = frame
        let image = PropArt.plantJiggle(frame)
        jiggleNode.texture = TextureFactory.texture(image)
        context.space.place(jiggleNode, at: ArtRect(origin: origin, size: image.size))
        jiggleNode.zPosition = context.placementZ(id) + 0.5
        jiggleNode.isHidden = false
        pl.root.isHidden = true
    }

    public var needsFrames: Bool { jiggle != nil }

    public func step(_ dt: Double) {
        guard var j = jiggle else { return }
        j.advance(dt)
        if j.isFinished {
            settle()
        } else {
            jiggle = j
            show(j.index)
        }
    }

    public func settle() {
        guard jiggle != nil else { return }
        jiggle = nil
        shownFrame = -1
        jiggleNode.isHidden = true
        placed()?.root.isHidden = false
    }
}
