import DeskCore
import SpriteKit

/// The pen cup (DESIGN §2.2 E7): a holder you can carry, flick over and stand back up, run by `PenCupMachine`.
///
/// - Tokens dropped on it become pens (cap in the kind's colour; six at most: the seventh bonks and the cup wobbles).
///   Press and drag on the pens pulls the last one out (LIFO) into a carry.
/// - Dragging the cup carries it as the desk plane's prop (velocity-driven, it shoves piles aside and stops at
///   furniture), leaning against the hand's acceleration; it stays on the desk. A flick faster than 400 px/s with at
///   least three pens tips it that way, as does the menu's Tip Over; a knock only wobbles it.
/// - Lying, it spills: each pen leaves the mouth in turn and slides as a pile (`PhysicsHub.spillPens`), aimed along
///   the flick that tipped it; the lying cup is furniture where it lies (`PenCupMachine.footprint`), so pens and piles
///   never end on it. A click or Stand Up rights it.
///
/// Resting states commit with `cupState`. It draws itself at its plane position over a contact shadow (the room's
/// static cup sprite is hidden), depth-sorted with the piles.
final class PenCupElement: DeskElement, Knockable {
    let id = "pencup"
    let root = SKNode()
    unowned let hub: PhysicsHub
    private(set) var machine = PenCupMachine()
    private let node = SKSpriteNode()
    /// The cup's sprite (hits) and the drawn image (the sprite over its shadow, same top-left).
    private var sprite = PixelBuffer(width: 1, height: 1)
    private var image = PixelBuffer(width: 1, height: 1)
    /// The flick that tipped it (plane px/s): the pens spill along it.
    private var flick: SIMD2<Float>?
    /// Canvas top-left of the drawn image.
    private(set) var origin = ArtPoint.zero
    private var drawnKey: String?
    /// The cup's drag in progress.
    private(set) weak var carry: CupCarry?

    init(hub: PhysicsHub) {
        self.hub = hub
        node.anchorPoint = .zero
        root.addChild(node)
    }

    var context: SceneContext { hub.context }

    var isCarried: Bool { carry != nil }

    /// Where the cup stands on the plane: the prop's position while carried.
    var position: SIMD2<Float> {
        if isCarried, let p = hub.world.propPosition, p.isFinite { return p - SIMD2(0, Self.footprintDepth / 2) }
        return machine.position
    }

    static let footprintDepth = DeskPlanePhysics.penCupFootprint(at: .zero).depth

    // MARK: State

    func layout(_ layout: SceneLayout) {
        hub.hidePlacements()
        drawnKey = nil
        redraw()
    }

    func apply(_ s: DeskState) {
        // Carried or mid-tip, the model holds the old state until the motion settles.
        if !isCarried, !machine.needsFrames { machine.sync(s.penCup) }
        updateFootprint()
        redraw()
    }

    func iconChanged() {}

    private func updateFootprint() {
        hub.world.setFurniture("pencup", isCarried ? nil : machine.footprint)
    }

    /// The pens in the cup on show (not one being pulled out).
    private var items: [InteriorRaster.Item] {
        guard let s = hub.state else { return [] }
        let hidden = hub.hiddenKeys
        return s.tokens.members(of: .penCup).filter { !hidden.contains($0) }.compactMap { k in
            s.tokens.meta(of: k).map { InteriorRaster.Item(key: k, meta: $0) }
        }
    }

    func redraw() {
        let items = items
        let pose = machine.pose
        let lean = machine.lean
        let key = "\(pose)\(machine.mirrored)\(lean)\(items.map(\.seed))"
        if key != drawnKey {
            drawnKey = key
            var cup = InteriorRaster.penCup(pose, mirrored: machine.mirrored, items: items).image
            if lean != 0, pose == .upright { cup = Self.sheared(cup, lean: lean) }
            sprite = cup
            image = PileArt.castShadow(of: cup, ink: .oak3, rows: PropArt.penCupShadowRows)
            node.texture = TextureFactory.texture(image)
        }
        let p = position
        let base = hub.canvas(plane: p)
        let bx = Int(base.x.rounded()), by = Int(base.y.rounded())
        let dx: Int
        switch pose {
        case .upright: dx = CoreLayout.penCup.w / 2
        // Tipping turns about the bottom corner on that side (sprite x 9 drawn right, 9 from the far end mirrored),
        // which stays where it stood.
        default: dx = machine.mirrored || pose == .lying(right: false) ? sprite.width - 9 : 9
        }
        origin = ArtPoint(bx - dx, by - sprite.height)
        context.space.place(node, at: ArtRect(origin: origin, size: image.size))
        node.zPosition = DeskPilesElement.z(d: p.y)
    }

    /// The upright cup leaning `lean` px at its top (a shear of whole rows).
    static func sheared(_ b: PixelBuffer, lean: Int) -> PixelBuffer {
        var out = PixelBuffer(width: b.width, height: b.height)
        for y in 0..<b.height {
            let shift = Int((Float(lean) * Float(b.height - 1 - y) / Float(max(1, b.height - 1))).rounded())
            for x in 0..<b.width where b.pixel(x, y).a != 0 {
                out[min(max(x + shift, 0), b.width - 1), y] = b[x, y]
            }
        }
        return out
    }

    // MARK: Hits

    var bounds: ArtRect { ArtRect(origin: origin, size: sprite.size) }

    /// The upright cup's mouth and the pens standing in it (canvas px): the whole strip takes presses, gaps too.
    var mouthRect: ArtRect { ArtRect(origin.x, origin.y, sprite.width, 8) }

    func hitTest(_ p: ArtPoint) -> Hit? {
        let mouth = machine.isUpright && !isCarried && mouthRect.contains(p)
        guard mouth || sprite.pixel(p.x - origin.x, p.y - origin.y).a != 0 else { return nil }
        return Hit(element: id, part: mouth ? "pencup.mouth" : "pencup", rect: bounds)
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        .image(sprite.outlined(RoomContent.hoverInk), at: ArtPoint(origin.x - 1, origin.y - 1))
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        guard let s = hub.state else { return nil }
        let names = s.tokens.members(of: .penCup).compactMap { s.tokens.meta(of: $0)?.displayName }
        let detail: String
        switch names.count {
        case 0: detail = "Empty"
        case 1: detail = "1 pen: " + names[0]
        default: detail = "\(names.count) pens: " + names.reversed().joined(separator: ", ")
        }
        var spec = TooltipSpec(title: "Pen Cup", detail: detail, anchor: hit.rect)
        spec.prefersAbove = true
        return spec
    }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard let s = hub.state else { return .pass }
        switch gesture {
        case let .click(_, _, count) where count == 1:
            if machine.isLying {
                standUp()
            } else {
                _ = machine.knock(strength: 0.5)
            }
            redraw()
            return .handled
        case let .dragBegan(from, at, _):
            guard machine.isUpright else { return .pass }
            let pens = s.tokens.members(of: .penCup).filter { !hub.hiddenKeys.contains($0) }
            if hit.part == "pencup.mouth", let last = pens.last {
                // The last pen out, into the hand.
                let r = bounds
                let session = CarrySession(keys: [last], origins: [ArtPoint(r.midX - 8, r.minY - 10)], grab: from,
                                           context: context)
                session.moved(to: at, mods: [])
                drawnKey = nil
                redraw()
                return .drag(session)
            }
            let drag = CupCarry(cup: self, grab: from)
            carry = drag
            hub.world.setFurniture("pencup", nil)
            hub.world.beginProp(at: machine.position + SIMD2(0, Self.footprintDepth / 2),
                                size: SIMD2(Float(CoreLayout.penCup.w), Self.footprintDepth))
            drag.moved(to: at, mods: [])
            return .drag(drag)
        default:
            return .pass
        }
    }

    /// Drops anywhere on the cup (or just above its pens) go in.
    func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? {
        guard !isCarried, ArtRect(origin.x - 2, origin.y - 4, sprite.width + 4, sprite.height + 4).contains(p),
              let s = hub.state else { return nil }
        let staying = s.tokens.members(of: .penCup).filter { !tokens.contains($0) }.count
        guard machine.isUpright else { return .bonk(nil) }
        guard staying + tokens.count <= ContainerSpec.penCup.hardCap else { return .bonk(.containerFull) }
        return .accept(.container(.penCup, order: s.tokens.count(in: .penCup)))
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        hub.state.map(MenuSpec.penCup)
    }

    func accessibilityItems() -> [AXItem] {
        let n = hub.state?.tokens.count(in: .penCup) ?? 0
        return [AXItem(id: "pencup", label: "Pen Cup, \(n) pen\(n == 1 ? "" : "s")", role: .container, frame: bounds)]
    }

    // MARK: Machine

    /// A refused drop: it wobbles.
    func bonked() {
        run(machine.bonk())
    }

    func knock(_ plan: DeskKnock.Plan) {
        // MARK: harden: a stilled knock (Reduce Motion) wobbles nothing.
        guard plan.wobbles[.penCup] != nil else { return }
        run(machine.knock(strength: plan.strength))
    }

    /// The menu's Tip Over: toward the side with more room.
    func tipOut() {
        guard machine.isUpright, !isCarried else { return }
        flick = nil
        run(machine.tipOut(right: tipsRight))
    }

    func standUp() {
        run(machine.standUp())
    }

    /// The side with more room before the next back-strip footprint (right on a tie).
    var tipsRight: Bool {
        let f = DeskPlanePhysics.penCupFootprint(at: machine.position)
        var left = f.x - DeskPlanePhysics.desk.x, right = DeskPlanePhysics.desk.x + DeskPlanePhysics.desk.width - f.x - f.width
        for o in DeskPlanePhysics.footprints.values where o.d < f.d + f.depth && f.d < o.d + o.depth {
            if o.x + o.width <= f.x { left = min(left, f.x - o.x - o.width) }
            if o.x >= f.x + f.width { right = min(right, o.x - f.x - f.width) }
        }
        return right >= left
    }

    private func run(_ events: [PenCupMachine.Event]) {
        for e in events {
            switch e {
            case let .spill(right):
                hub.spillPens(right: right, from: machine.position, direction: flick)
                flick = nil
            case let .settled(state):
                context.dispatch(.cupState(state))
            case .wobble, .bonk, .tipped, .righted:
                break
            }
        }
        updateFootprint()
        redraw()
    }

    // MARK: Carry

    /// The hand moved the cup toward plane point `target`.
    func carry(to target: SIMD2<Float>, acceleration: SIMD2<Float>) {
        machine.carry(to: target, acceleration: acceleration)
        hub.bodies.thaw(near: position)
        redraw()
    }

    /// Let go with plane velocity `velocity`: it settles where the prop stopped, or tips over.
    func release(velocity: SIMD2<Float>) {
        if let p = hub.world.propPosition, p.isFinite {
            machine.carry(to: p - SIMD2(0, Self.footprintDepth / 2), acceleration: .zero)
        }
        hub.world.endProp()
        carry = nil
        let pens = hub.state?.tokens.count(in: .penCup) ?? 0
        flick = velocity.isFinite ? velocity : nil
        run(machine.release(velocity: velocity, count: pens))
    }

    /// Esc: back where it was picked up.
    func cancelCarry(to start: PenCupState) {
        hub.world.endProp()
        carry = nil
        machine.sync(start)
        if let s = hub.state { machine.sync(s.penCup) }
        updateFootprint()
        redraw()
    }

    /// After the physics step: the carried cup follows its prop.
    func afterPhysics() {
        if isCarried { redraw() }
    }

    // MARK: Frames

    var needsFrames: Bool { machine.needsFrames || isCarried }

    func step(_ dt: Double) {
        if isCarried {
            hub.world.driveProp(toward: machine.position + SIMD2(0, Self.footprintDepth / 2), dt: Float(dt))
        }
        let events = machine.step(Float(dt))
        if events.isEmpty {
            if machine.needsFrames { redraw() }
        } else {
            run(events)
        }
    }

    func settle() {
        carry?.end(velocity: .zero)
        var guardSteps = 0
        while machine.needsFrames && guardSteps < 600 {
            step(1.0 / 60)
            guardSteps += 1
        }
        redraw()
    }
}

/// Dragging the pen cup (DESIGN §2.2 E7): the plane point under the hand, less where the cup was grabbed, is where
/// the cup goes; the release's plane velocity (`vd = −2·vy`) may tip it.
final class CupCarry: DragController {
    private unowned let cup: PenCupElement
    /// Cup position minus the plane point under the pointer, at the grab.
    private let offset: SIMD2<Float>
    private let start: PenCupState
    private var last: (target: SIMD2<Float>, velocity: SIMD2<Float>, t: Double)?
    private(set) var isFinished = false

    init(cup: PenCupElement, grab: SIMD2<Float>) {
        self.cup = cup
        start = cup.machine.state
        offset = cup.machine.position - cup.hub.plane(grab)
    }

    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard !isFinished else { return }
        let target = cup.hub.plane(p) + offset
        let now = cup.hub.eventTime()
        var acceleration = SIMD2<Float>.zero
        var velocity = SIMD2<Float>.zero
        if let last, now > last.t {
            let dt = Float(now - last.t)
            velocity = (target - last.target) / dt
            acceleration = (velocity - last.velocity) / dt
        }
        last = (target, velocity, now)
        cup.carry(to: target, acceleration: acceleration)
    }

    func ended(at p: SIMD2<Float>, velocity: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard !isFinished else { return }
        moved(to: p, mods: mods)
        end(velocity: SIMD2(velocity.x, -velocity.y / DeskProjection.standard.k))
    }

    /// Ends the carry with plane velocity `velocity`.
    func end(velocity: SIMD2<Float>) {
        guard !isFinished else { return }
        isFinished = true
        cup.release(velocity: velocity)
    }

    func cancelled() {
        guard !isFinished else { return }
        isFinished = true
        cup.cancelCarry(to: start)
    }

    func step(_ dt: Double) {}
    var needsFrames: Bool { false }
}
