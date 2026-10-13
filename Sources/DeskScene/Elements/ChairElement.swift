import DeskCore
import SpriteKit

/// The rolling chair (DESIGN §2.2 E6): drag it along the floor (`RollerSim`); let go moving and it coasts, keeping
/// 60% of the fling, spinning through its four facings when fast, bouncing off the desk leg and the cabinet side.
/// An open cabinet drawer stops it rolling in (a thunk); a cabinet drawer opening into it pushes it aside. It
/// commits `.chair(x, facing)` when it comes to rest, and rolls to a position the model sets elsewhere (Show on
/// Desk clearing the cabinet). Drawn here in place of the room's chair sprite once a model arrives.
final class ChairElement: ContainerElement, DeskElement {
    let id = "chair"
    private(set) var sim = RollerSim(x: Float(CoreLayout.chair.x))
    private var modelX: Float?
    weak var cabinet: CabinetElement?
    private let node = SKSpriteNode()
    private var shown: (x: Int, facing: PropArt.ChairFacing)?
    private var sprites: [PropArt.ChairFacing: PixelBuffer] = [:]

    /// The seat in sprite px (where a drawer meets the chair).
    static let seat = ArtRect(6, 33, 60, 18)

    override init(context: SceneContext) {
        super.init(context: context)
        node.isHidden = true
        root.addChild(node)
    }

    override var drawnPlacements: [String] { ["chair"] }

    // MARK: Geometry

    /// The sprite's top-left (canvas px).
    var origin: ArtPoint { context.layout.point(ArtPoint(sim.pixelX, CoreLayout.chair.y)) }
    var image: PixelBuffer {
        let f = sim.chairFacing
        if let b = sprites[f] { return b }
        let b = PropArt.chair(f).image
        sprites[f] = b
        return b
    }
    var rect: ArtRect { ArtRect(origin: origin, size: image.size) }
    var seatRect: ArtRect { Self.seat.offsetBy(origin.x, origin.y) }

    /// A cabinet drawer ran into the chair.
    func pushedByDrawer() { sim.pushedByDrawer() }

    // MARK: DeskElement

    func layout(_ layout: SceneLayout) {
        shown = nil
        hidePlaced()
        render()
    }

    func apply(_ s: DeskState) {
        adopt(s)
        let x = s.chair.x
        if modelX == nil {
            sim = RollerSim(s.chair)
        } else if x != modelX, !sim.isDragging, abs(x - sim.x) >= 1 {
            sim.roll(to: x)
        }
        modelX = x
        render()
    }

    func hitTest(_ p: ArtPoint) -> Hit? {
        let r = rect
        guard r.contains(p), image.pixel(p.x - r.x, p.y - r.y).a != 0 else { return nil }
        return Hit(element: id, part: nil, rect: r)
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle { Self.outline(image, at: origin) }

    func tooltip(_ hit: Hit) -> TooltipSpec? { TooltipSpec(title: "Chair", anchor: hit.rect) }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard state != nil else { return .pass }
        switch gesture {
        case let .dragBegan(from, at, mods):
            let roll = ChairRoll(chair: self, from: from)
            roll.moved(to: at, mods: mods)
            return .drag(roll)
        case .press, .cancelPress:
            return .handled
        case .click, .scroll:
            return .pass
        }
    }

    func accessibilityItems() -> [AXItem] {
        state == nil ? [] : [AXItem(id: "chair", label: "Chair", role: .group, frame: rect)]
    }

    // MARK: Drag

    /// Core x of a canvas x.
    func coreX(_ canvasX: Float) -> Float { canvasX - Float(context.layout.coreOrigin.x) }

    func beginRoll(at canvasX: Float) { sim.beginDrag(pointerX: coreX(canvasX)) }
    func roll(to canvasX: Float) { sim.drag(pointerX: coreX(canvasX)) }
    func endRoll(velocity: Float) { sim.endDrag(releaseVelocity: velocity) }

    // MARK: Frames

    var needsFrames: Bool { sim.needsFrames }

    func step(_ dt: Double) {
        sim.setBlock(cabinet?.blocksChair == true ? RollerSim.cabinetBlockX() : nil)
        handle(sim.step(Float(dt)))
        if render() { refreshHover() }
    }

    func settle() {
        handle(sim.forceRest())
        render()
    }

    private func handle(_ events: [RollerSim.Event]) {
        for e in events {
            switch e {
            case let .settled(x, facing):
                context.dispatch(.chair(x, facing))
            case .blockedByDrawer:
                // Thunk: the seat runs into an open cabinet drawer.
                let seat = seatRect
                context.fx.sparkle(at: ArtPoint(seat.maxX - 2, seat.midY))
                context.shake(frames: 1)
            case let .bump(speed, _) where speed > 200:
                context.shake(frames: 1)
            default:
                break
            }
        }
    }

    /// Redraws when the chair moved or turned (true then).
    @discardableResult
    func render() -> Bool {
        guard state != nil else { return false }
        let now = (sim.pixelX, sim.chairFacing)
        if let s = shown, s.x == now.0, s.facing == now.1 { return false }
        let moved = shown != nil
        shown = now
        let image = self.image
        node.texture = TextureFactory.texture(image)
        context.space.place(node, at: ArtRect(origin: origin, size: image.size))
        node.zPosition = context.placementZ("chair")
        node.isHidden = false
        return moved
    }
}

/// The pointer rolling the chair: it follows along the floor; the release flings it.
final class ChairRoll: DragController {
    private unowned let chair: ChairElement
    private(set) var isFinished = false

    init(chair: ChairElement, from: SIMD2<Float>) {
        self.chair = chair
        chair.beginRoll(at: from.x)
    }

    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard !isFinished else { return }
        chair.roll(to: p.x)
    }

    func ended(at p: SIMD2<Float>, velocity: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard !isFinished else { return }
        chair.roll(to: p.x)
        chair.endRoll(velocity: velocity.x)
        isFinished = true
    }

    func cancelled() {
        guard !isFinished else { return }
        chair.endRoll(velocity: 0)
        isFinished = true
    }

    func step(_ dt: Double) {}
    var needsFrames: Bool { false }
}
