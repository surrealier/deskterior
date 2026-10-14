import DeskCore
import SpriteKit

/// The wastebasket (DESIGN §2.2 E8, Errata 13): it hides, never deletes. Run by `WastebasketMachine`.
///
/// - What goes in shows as crumpled balls in the heap slots (`InteriorRaster.basketSlots`; above the rim from the
///   11th); the 25th bonks. A gentle drop at the mouth hops in; tosses come in by `Ballistics` (SWISH! for a clean
///   pass, counted; a ball that touches a rim jiggles the basket 1 px with a spark). Nothing ever leaves on its own.
/// - A drag from the rim that goes up out of the mouth (or 14 px any way but sideways) digs: the top ball comes out
///   into the hand as its token. A sustained sideways rim drag (three samples in a row faster than 300 px/s, three
///   times more across than up or down, over 6 px) tips the basket that way instead: the balls roll out onto the
///   floor (`WastebasketMachine.spillSpots`) and uncrumple. A click (or Stand Up) rights it. A knock only jiggles the
///   heap. Lying, it takes nothing: a drop on it bonks.
/// - Empty Wastebasket… stays disabled until `FileOperator` lands (M11).
///
/// Resting states commit with `basketState`. It draws itself (the room's static basket sprites are hidden).
final class WastebasketElement: DeskElement, Knockable {
    let id = "wastebasket"
    let root = SKNode()
    unowned let hub: PhysicsHub
    private(set) var machine = WastebasketMachine()
    private let node = SKSpriteNode()
    private var image = PixelBuffer(width: 1, height: 1)
    private(set) var origin = ArtPoint.zero
    private var drawnKey: String?
    /// Frames left of a 1-px sideways shake (a rim hit, a refused drop), and the offset drawn.
    private var shakeFrames = 0
    private var shakeOffset = 0
    /// The rim drag in progress (a dig hands its carry over through it).
    private(set) weak var rimDrag: BasketRimDrag?

    init(hub: PhysicsHub) {
        self.hub = hub
        node.anchorPoint = .zero
        root.addChild(node)
    }

    var context: SceneContext { hub.context }

    var isUpright: Bool { machine.isUpright }

    // MARK: State

    func layout(_ layout: SceneLayout) {
        drawnKey = nil
        redraw()
    }

    func apply(_ s: DeskState) {
        // Mid-tip the model still holds the old state until the motion settles.
        if machine.tipFrame == nil { machine.sync(s.wastebasket) }
        redraw()
    }

    func iconChanged() {}

    private var items: [InteriorRaster.Item] {
        guard let s = hub.state else { return [] }
        let hidden = hub.hiddenKeys
        return s.tokens.members(of: .wastebasket).filter { !hidden.contains($0) }.compactMap { k in
            s.tokens.meta(of: k).map { InteriorRaster.Item(key: k, meta: $0) }
        }
    }

    func redraw() {
        let r = CoreLayout.wastebasket
        let foot = context.layout.point(ArtPoint(r.midX, r.maxY))
        let items = items
        let key: String
        let make: () -> SpriteAsset
        if let tip = machine.tipFrame {
            key = "tip\(tip.frame)\(tip.right)"
            make = { InteriorRaster.wastebasketTipped(frame: tip.frame, right: tip.right) }
        } else if case let .tipped(right) = machine.phase {
            key = "lying\(right)"
            make = { InteriorRaster.wastebasketTipped(frame: nil, right: right) }
        } else {
            let lift = -machine.jiggleOffset
            key = "up\(lift)\(items.map(\.seed))"
            make = { InteriorRaster.wastebasket(items, lift: lift) }
        }
        let shake = shakeFrames > 0 ? (shakeFrames % 4 < 2 ? 1 : -1) : 0
        if key != drawnKey {
            drawnKey = key
            let sprite = make()
            image = sprite.image
            node.texture = TextureFactory.texture(image)
            origin = ArtPoint(foot.x - sprite.anchor.x, foot.y - sprite.anchor.y)
            shakeOffset = Int.min
        }
        if shake != shakeOffset {
            shakeOffset = shake
            context.space.place(node, at: ArtRect(origin: ArtPoint(origin.x + shake, origin.y), size: image.size))
        }
        node.zPosition = context.placementZ("wastebasket.front")
    }

    // MARK: Hits

    var bounds: ArtRect { ArtRect(origin: origin, size: image.size) }

    /// The mouth (canvas px), with the rim.
    var mouthRect: ArtRect { context.layout.rect(CoreLayout.wastebasketMouth) }

    func hitTest(_ p: ArtPoint) -> Hit? {
        guard image.pixel(p.x - origin.x, p.y - origin.y).a != 0 else { return nil }
        let mouth = machine.isUpright && mouthRect.insetBy(0, -3).contains(p)
        return Hit(element: id, part: mouth ? "wastebasket.mouth" : "wastebasket", rect: mouth ? mouthRect : bounds)
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        .image(image.outlined(RoomContent.hoverInk), at: ArtPoint(origin.x - 1, origin.y - 1))
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        let n = hub.state?.tokens.count(in: .wastebasket) ?? 0
        let detail = n == 0 ? "Empty" : "\(n) item\(n == 1 ? "" : "s") — hidden, not deleted."
        var spec = TooltipSpec(title: "Wastebasket", detail: detail, anchor: hit.rect)
        spec.prefersAbove = true
        return spec
    }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        switch gesture {
        case let .click(_, _, count) where count == 1:
            if machine.isTipped {
                run(machine.standUp())
            } else {
                jiggle()
            }
            return .handled
        case let .dragBegan(from, at, _):
            guard machine.isUpright else { return .pass }
            let drag = BasketRimDrag(basket: self, from: from, t: hub.eventTime())
            rimDrag = drag
            drag.moved(to: at, mods: [])
            return .drag(drag)
        default:
            return .pass
        }
    }

    /// A gentle drop within 12 px of the mouth goes in (the hub hops it there); a full basket bonks, and so does the
    /// basket lying on its side.
    func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? {
        if machine.isTipped, image.pixel(p.x - origin.x, p.y - origin.y).a != 0 { return .bonk(nil) }
        guard machine.isUpright, let s = hub.state else { return nil }
        let core = ArtPoint(p.x - context.layout.coreOrigin.x, p.y - context.layout.coreOrigin.y)
        guard machine.isGentleDrop(at: core) else { return nil }
        let staying = s.tokens.members(of: .wastebasket).filter { !tokens.contains($0) }.count
        guard staying + tokens.count <= ContainerSpec.wastebasket.hardCap else { return .bonk(.containerFull) }
        return .accept(.container(.wastebasket, order: s.tokens.count(in: .wastebasket)))
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        hub.state.map(MenuSpec.wastebasket)
    }

    func accessibilityItems() -> [AXItem] {
        let n = hub.state?.tokens.count(in: .wastebasket) ?? 0
        return [AXItem(id: "wastebasket", label: "Wastebasket, \(n) item\(n == 1 ? "" : "s"), hidden, not deleted",
                       role: .container, frame: bounds)]
    }

    // MARK: Machine

    /// A toss that ended in the basket: true for a swish (counted and committed).
    func recordToss(_ toss: Ballistics.Toss, count: Int) -> Bool {
        let events = machine.recordToss(toss, count: count)
        run(events)
        return events.contains(.swish)
    }

    /// A refused drop: the heap jiggles and the basket shakes (neither with Reduce Motion).
    func bonked() {
        shake()
        jiggle()
    }

    /// A ball touched a rim at core point `p` (its centre): the basket jiggles 1 px (not with Reduce Motion) and the
    /// rim sparks.
    func rimHit(at p: SIMD2<Float>) {
        shake()
        let rim = p.x < Float(CoreLayout.wastebasketMouth.midX) ? CoreLayout.wastebasketMouth.minX + 1
            : CoreLayout.wastebasketMouth.maxX - 2
        context.fx.sparkle(at: context.layout.point(ArtPoint(rim, CoreLayout.wastebasketMouth.minY - 2)))
        redraw()
    }

    // MARK: harden: Reduce Motion (Errata 15: no shake, no jiggle) holds the basket still.
    private func shake() {
        guard !context.reduceMotion else { return }
        shakeFrames = 6
    }

    /// The heap jiggles (a click, a refused drop), unless Reduce Motion is on.
    private func jiggle() {
        if context.reduceMotion { return redraw() }
        run(machine.knock())
    }

    func knock(_ plan: DeskKnock.Plan) {
        if plan.basketJiggle { run(machine.knock()) }
    }

    /// The menu's Tip Over: toward the room.
    func tipOut() {
        run(machine.tipOut(right: true))
    }

    func standUp() {
        run(machine.standUp())
    }

    /// One rim-drag sample (`delta` core px over `dt` s): true once it tipped the basket.
    func rimSample(delta: SIMD2<Float>, dt: Float) -> Bool {
        let events = machine.rimDrag(delta: delta, dt: dt)
        run(events)
        return !machine.isUpright
    }

    func endRimDrag() {
        machine.endRimDrag()
    }

    /// The top ball comes out into the hand as its token (nil when there is none to dig).
    func dig(from: SIMD2<Float>, at p: SIMD2<Float>) -> CarrySession? {
        guard machine.canDig(count: items.count), let s = hub.state else { return nil }
        let hidden = hub.hiddenKeys
        let inside = s.tokens.members(of: .wastebasket).filter { !hidden.contains($0) }
        guard let top = inside.last, let slot = WastebasketMachine.heapSlot(inside.count - 1) else { return nil }
        machine.endRimDrag()
        // The ball's centre, in canvas px: the heap image sits `heapRise` above the basket.
        let r = context.layout.rect(CoreLayout.wastebasket)
        let ball = ArtPoint(r.x + slot.x + 4, r.y + slot.y + 4)
        let session = CarrySession(keys: [top], origins: [ArtPoint(ball.x - 8, ball.y - 8)], grab: from, context: context)
        session.moved(to: p, mods: [])
        drawnKey = nil
        redraw()
        return session
    }

    private func run(_ events: [WastebasketMachine.Event]) {
        for e in events {
            switch e {
            case let .spill(right):
                hub.spillBalls(right: right)
            case let .settled(state):
                context.dispatch(.basketState(state))
            case .bonk, .swish, .rim, .tipped, .righted:
                break
            }
        }
        redraw()
    }

    // MARK: Frames

    var needsFrames: Bool { machine.needsFrames || shakeFrames > 0 }

    func step(_ dt: Double) {
        shakeFrames = max(0, shakeFrames - 1)
        let events = machine.step(Float(dt))
        if events.isEmpty { redraw() } else { run(events) }
    }

    func settle() {
        shakeFrames = 0
        rimDrag?.finishNow()
        var guardSteps = 0
        while machine.needsFrames && guardSteps < 600 {
            step(1.0 / 60)
            guardSteps += 1
        }
        redraw()
    }
}

/// A drag that started on the upright basket (DESIGN §2.2 E8, Errata 13): each pointer sample feeds the basket's
/// tip rule; a drag that goes up out of the mouth, or more than 14 px without going mostly sideways, digs instead
/// (a sideways drag never digs, however it starts), and from then on carries the dug token (`CarrySession`). Speeds
/// are measured between pointer samples; the first one, at the drag's start, only sets where they start from.
final class BasketRimDrag: DragController {
    private unowned let basket: WastebasketElement
    private let start: SIMD2<Float>
    private var last: (p: SIMD2<Float>, t: Double)
    private var streak = 0
    private var tipped = false
    private var ended = false
    private(set) var carry: CarrySession?

    /// Up this far out of the mouth, or this far in all (not mostly sideways), a drag digs.
    static let digLift: Float = 4
    static let digDistance: Float = 14
    /// A drag this many times more across than up or down is sideways: it may tip the basket, never dig.
    static let sidewaysAspect: Float = 2

    init(basket: WastebasketElement, from: SIMD2<Float>, t: Double) {
        self.basket = basket
        start = from
        last = (from, t)
    }

    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers) {
        if let carry {
            carry.moved(to: p, mods: mods)
            return
        }
        guard !tipped, !ended else { return }
        let now = basket.hub.eventTime()
        let elapsed = now - last.t
        let delta = p - last.p
        last = (p, now)
        // No time since the last sample (the drag's first move): nothing to measure a speed over.
        if elapsed > 0, delta != .zero {
            let dt = Float(max(elapsed, 1.0 / 240))
            if basket.rimSample(delta: delta, dt: dt) {
                tipped = true
                return
            }
            let params = basket.machine.params
            let v = delta / dt
            let fast = abs(v.x) > params.tipSpeed && abs(v.x) > params.tipAspect * abs(v.y)
            streak = fast ? streak + 1 : 0
        }
        let total = p - start
        let sideways = abs(total.x) > Self.sidewaysAspect * abs(total.y)
        if streak == 0, !sideways, total.y <= -Self.digLift || simd_length(total) > Self.digDistance {
            carry = basket.dig(from: start, at: p)
        }
    }

    func ended(at p: SIMD2<Float>, velocity: SIMD2<Float>, mods: InputEvent.Modifiers) {
        if let carry {
            carry.ended(at: p, velocity: velocity, mods: mods)
            return
        }
        ended = true
        basket.endRimDrag()
    }

    func cancelled() {
        if let carry {
            carry.cancelled()
            return
        }
        ended = true
        basket.endRimDrag()
    }

    /// Hard sleep: a dug token goes home (or lands) at once.
    func finishNow() {
        carry?.finishNow()
        ended = true
    }

    func step(_ dt: Double) { carry?.step(dt) }
    var needsFrames: Bool { carry?.needsFrames ?? false }
    var isFinished: Bool { carry?.isFinished ?? (ended || tipped) }
}
