import DeskCore
import SpriteKit

/// The desk brush (빗자루; DESIGN §2.2 E10) and the scroll-broom. Dragging the brush makes it the desk plane's prop,
/// driven straight at the pointer by velocity (`DeskPlanePhysics.propDrive`, no joint, about 20× a pile's mass), so it
/// shoves piles ahead of it: into the mat, where they tuck under (the mat's coverage hides them), or over the desk's
/// front or side edge, where they leave on an arc. It never throws: on release it stops where it is and commits
/// there (`brushSettled`). While it moves its bristles flick between two frames and up to six dust motes rise behind
/// it. A double-click sends it home to its rest spot. A horizontal two-finger scroll over the desk drives an invisible
/// broom along the scroll from the pointer (the mat's slot hands it the scroll). Clear the Desk drives it along its
/// pass (`scripted`). The bare room keeps its placed sprite; with a model the brush draws itself.
final class BrushElement: DeskElement {
    let id = "brush"
    let root = SKNode()
    unowned let context: SceneContext
    let placed: () -> PlacedElement?
    private let node = SKSpriteNode()
    private let motesNode = SKSpriteNode()
    /// Desk-plane centre of the brush's footprint (`BrushState.pos`).
    private(set) var position = BrushState().pos
    private(set) var isLive = false
    /// A drag in hand: where the pointer wants the brush (plane px) and the pointer's offset from its centre.
    private(set) var dragTarget: SIMD2<Float>?
    private var grabOffset = SIMD2<Float>.zero
    /// Sliding home after a double-click.
    private var homing: (from: SIMD2<Float>, t: Float)?
    /// Clear the Desk's pass drives it here.
    var scripted: SIMD2<Float>? {
        didSet {
            if let p = scripted { move(to: p) } else if let s = context.state, dragTarget == nil, homing == nil {
                move(to: s.brush.pos)
            }
        }
    }
    /// The scroll-broom in use: where its invisible body is headed and how long the scroll has been still.
    private(set) var broomRun: (target: SIMD2<Float>, still: Double)?
    private var bristle = 0
    private var stepsMoving = 0
    private var motes: [(p: SIMD2<Float>, age: Double)] = []
    private var drawn: (origin: ArtPoint, frame: Int)?
    private var lastPosition = BrushState().pos

    static let frames = PropArt.brush().frames
    /// Sprite top-left from the footprint's centre (core px): the rest spot (plane 442, 60) draws at core (430, 196).
    static let spriteOffset = SIMD2<Float>(-12, -6)
    /// The scroll-broom stands across its sweep: 6 plane px wide, 24 deep.
    static let broomSize = SIMD2<Float>(6, 24)
    /// Scroll px → plane px for the scroll-broom, and the still time that ends it.
    static let broomGain: Float = 1.5
    static let broomStill = 0.25
    static let homeSeconds: Float = 0.35
    static let maxMotes = 6

    init(context: SceneContext, placed: @escaping () -> PlacedElement?) {
        self.context = context
        self.placed = placed
        node.isHidden = true
        root.addChild(node)
        motesNode.isHidden = true
        root.addChild(motesNode)
    }

    var hub: PhysicsHub? { context.physics }

    // MARK: State

    func layout(_ layout: SceneLayout) {
        drawn = nil
        if isLive {
            placed()?.root.isHidden = true
            redraw()
        }
    }

    func apply(_ s: DeskState) {
        if !isLive {
            isLive = true
            node.isHidden = false
            placed()?.root.isHidden = true
        }
        if dragTarget == nil, homing == nil, scripted == nil { move(to: s.brush.pos) }
    }

    private func move(to p: SIMD2<Float>) {
        guard p.isFinite else { return }
        position = p
        redraw()
    }

    // MARK: Drawing

    /// The sprite's canvas rect where the brush is now.
    var rect: ArtRect {
        guard let hub else { return ArtRect(origin: context.layout.point(CoreLayout.brush.origin), size: CoreLayout.brush.size) }
        let c = hub.canvas(plane: position) + Self.spriteOffset
        return ArtRect(Int(c.x.rounded()), Int(c.y.rounded()), CoreLayout.brush.w, CoreLayout.brush.h)
    }

    private func redraw() {
        guard isLive else { return }
        let r = rect
        let frame = bristle
        if drawn?.origin != r.origin || drawn?.frame != frame {
            node.texture = TextureFactory.texture(Self.frames[frame])
            context.space.place(node, at: r)
            drawn = (r.origin, frame)
        }
        node.zPosition = DeskPilesElement.z(d: position.y) - 0.5
    }

    // MARK: Hits

    func hitTest(_ p: ArtPoint) -> Hit? {
        guard isLive else { return placed()?.hitTest(p).map { Hit(element: id, part: $0.part, rect: $0.rect) } }
        let r = rect
        guard r.contains(p), Self.frames[bristle].pixel(p.x - r.x, p.y - r.y).a != 0 else { return nil }
        return Hit(element: id, part: "brush", rect: r)
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        let r = rect
        return .image(Self.frames[bristle].outlined(RoomContent.hoverInk), at: ArtPoint(r.x - 1, r.y - 1))
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        var spec = TooltipSpec(title: "Desk Brush", detail: "Drag to sweep piles", anchor: hit.rect)
        spec.prefersAbove = true
        return spec
    }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard isLive, let hub else { return .pass }
        switch gesture {
        case .press, .cancelPress:
            return .handled
        case let .click(_, _, count):
            guard count == 2, scripted == nil else { return .handled }
            goHome()
            return .handled
        case let .dragBegan(from, at, _):
            guard scripted == nil, !hub.world.hasProp else { return .handled }
            endBroom()
            homing = nil
            grabOffset = position - hub.plane(from)
            hub.world.beginProp(at: position, size: DeskPlanePhysics.brushSize)
            hub.world.attach(to: hub.world.root.scene)
            aim(at: at)
            return .drag(BrushDrag(brush: self))
        case .scroll:
            return .pass
        }
    }

    /// Points the dragged brush at canvas point `p` (kept on the desk top).
    func aim(at p: SIMD2<Float>) {
        guard let hub else { return }
        dragTarget = Self.onDesk(hub.plane(p) + grabOffset, size: DeskPlanePhysics.brushSize)
    }

    /// Let go: the brush stops where it is and commits there.
    func release() {
        guard dragTarget != nil, let hub else { return }
        if let p = hub.world.propPosition, p.isFinite { position = p }
        hub.world.endProp()
        dragTarget = nil
        redraw()
        context.dispatch(.brushSettled(position))
    }

    /// Double-click: back to the rest spot.
    func goHome() {
        guard dragTarget == nil else { return }
        homing = (position, 0)
    }

    static func onDesk(_ p: SIMD2<Float>, size: SIMD2<Float>) -> SIMD2<Float> {
        let desk = DeskPlanePhysics.desk
        return SIMD2(min(max(p.x, desk.x + size.x / 2), desk.x + desk.width - size.x / 2),
                     min(max(p.y, desk.d + size.y / 2), desk.d + desk.depth - size.y / 2))
    }

    // MARK: Scroll-broom

    /// A horizontal scroll of `dx` art px over the desk at canvas point `p`: the invisible broom starts at the pointer
    /// (or carries on from where it is) and is driven `dx × broomGain` plane px along the desk.
    func broom(at p: SIMD2<Float>, dx: Float) {
        guard isLive, let hub, dx.isFinite, dragTarget == nil, scripted == nil else { return }
        if var run = broomRun {
            run.target = Self.onDesk(run.target + SIMD2(dx * Self.broomGain, 0), size: Self.broomSize)
            run.still = 0
            broomRun = run
            return
        }
        guard !hub.world.hasProp else { return }
        let start = Self.onDesk(hub.plane(p), size: Self.broomSize)
        hub.world.beginProp(at: start, size: Self.broomSize)
        hub.world.attach(to: hub.world.root.scene)
        broomRun = (Self.onDesk(start + SIMD2(dx * Self.broomGain, 0), size: Self.broomSize), 0)
    }

    private func endBroom() {
        guard broomRun != nil else { return }
        broomRun = nil
        hub?.world.endProp()
    }

    /// Where the invisible broom is (plane px), while it sweeps.
    var broomPosition: SIMD2<Float>? { broomRun == nil ? nil : hub?.world.propPosition }

    // MARK: Frames

    var needsFrames: Bool {
        isLive && (dragTarget != nil || homing != nil || broomRun != nil || !motes.isEmpty || scripted != nil)
    }

    func step(_ dt: Double) {
        guard isLive, let hub else { return }
        let dtf = Float(dt)
        if let target = dragTarget {
            if let p = hub.world.propPosition, p.isFinite { position = p }
            hub.world.driveProp(toward: target, dt: dtf)
            hub.bodies.thaw(near: position)
        } else if var h = homing {
            h.t = min(1, h.t + dtf / Self.homeSeconds)
            let e = h.t * h.t * (3 - 2 * h.t)
            position = h.from + (BrushState().pos - h.from) * e
            homing = h.t >= 1 ? nil : h
            if homing == nil { context.dispatch(.brushSettled(position)) }
        } else if let p = scripted {
            position = p
        }
        if hub.cup.isCarried, broomRun != nil {
            // The pen cup took the desk plane's one prop slot.
            broomRun = nil
        }
        if var run = broomRun {
            hub.world.driveProp(toward: run.target, dt: dtf)
            if let p = hub.world.propPosition { hub.bodies.thaw(near: p) }
            run.still += dt
            let arrived = hub.world.propPosition.map { simd_length($0 - run.target) < 1 } ?? true
            broomRun = run
            if run.still >= Self.broomStill && arrived { endBroom() }
        }
        animate(dt)
        redraw()
    }

    /// Bristles flick while the brush moves; dust motes rise from behind its head and fade.
    private func animate(_ dt: Double) {
        let moved = simd_length(position - lastPosition)
        let direction = position.x - lastPosition.x
        lastPosition = position
        if moved > 0.2 {
            stepsMoving += 1
            bristle = (stepsMoving / 4) % 2
            if !context.reduceMotion, stepsMoving % 5 == 1, motes.count < Self.maxMotes, let hub {
                let head = position + SIMD2(direction >= 0 ? -10 : 10, 0)
                motes.append((hub.canvas(plane: head) + SIMD2(Float(stepsMoving % 3) - 1, -1), 0))
            }
        } else {
            stepsMoving = 0
            bristle = 0
        }
        for i in motes.indices { motes[i].age += dt }
        motes.removeAll { $0.age > 0.45 }
        drawMotes()
    }

    private func drawMotes() {
        guard !motes.isEmpty else {
            motesNode.isHidden = true
            return
        }
        let pts = motes.map { m -> (ArtPoint, Ink) in
            let lift = Float(m.age) * 10
            let p = ArtPoint(Int(m.p.x.rounded()), Int((m.p.y - lift).rounded()))
            return (p, m.age < 0.2 ? .neutral8 : .neutral7)
        }
        let xs = pts.map(\.0.x), ys = pts.map(\.0.y)
        let origin = ArtPoint(xs.min()!, ys.min()!)
        var c = PixelCanvas(width: xs.max()! - origin.x + 1, height: ys.max()! - origin.y + 1)
        for (p, ink) in pts { c.plot(p.x - origin.x, p.y - origin.y, ink) }
        motesNode.texture = TextureFactory.texture(c.buffer)
        context.space.place(motesNode, at: ArtRect(origin: origin, size: c.buffer.size))
        motesNode.zPosition = node.zPosition + 0.25
        motesNode.isHidden = false
    }

    /// Hard sleep: a drag lets go, the trip home ends, the broom stops.
    func settle() {
        if dragTarget != nil { release() }
        if let h = homing {
            homing = nil
            position = BrushState().pos
            if h.from != position { context.dispatch(.brushSettled(position)) }
        }
        endBroom()
        motes.removeAll()
        drawMotes()
        bristle = 0
        redraw()
    }
}

/// A brush drag in hand: the pointer aims the brush; letting go (or Esc) stops it where it is.
final class BrushDrag: DragController {
    unowned let brush: BrushElement
    private(set) var isFinished = false

    init(brush: BrushElement) {
        self.brush = brush
    }

    var needsFrames: Bool { !isFinished }

    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard !isFinished else { return }
        brush.aim(at: p)
    }

    func ended(at p: SIMD2<Float>, velocity: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard !isFinished else { return }
        isFinished = true
        brush.release()
    }

    func cancelled() {
        guard !isFinished else { return }
        isFinished = true
        brush.release()
    }

    func step(_ dt: Double) {}
}
