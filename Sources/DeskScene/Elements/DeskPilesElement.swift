import DeskCore
import SpriteKit

/// Loose piles on the desk top (DESIGN §2.2 E11): each pile stands where its body is (`PhysicsHub`), as up to three
/// 16×16 icons with a count tag over a contact shadow (`PileArt.stack`), its base on the projected desk point
/// (`DeskProjection`), snapped to whole px with 0.75-px hysteresis. Piles nearer the front draw over the ones
/// behind them and over the desk-front props behind them. It also answers drops on the bare desk top (not over the
/// back-strip furniture, whose own elements answer there) and runs the hub's per-frame work.
///
/// Gestures: a press selects the pile's tokens (⌘ adds or removes them), a double-click opens them, a drag carries
/// them (`CarrySession`: back to the screen, into a container, or flung), right-click is the token menu. A knock
/// hops every pile 2 px (visual only).
final class DeskPilesElement: DeskElement, Knockable {
    let id = "desk.piles"
    let root = SKNode()
    unowned let hub: PhysicsHub

    private struct Shown {
        var keys: [TokenKey]
        var lift: Int
        var selected: Bool
        var stack: PileArt.Stack
        /// Canvas px of the stack's base.
        var base: ArtPoint
        var node: SKSpriteNode
        var d: Float
    }

    private var shown: [PileID: Shown] = [:]
    /// Drawn base points with the hysteresis applied.
    private var snapped: [PileID: ArtPoint] = [:]
    private var hops: (plan: DeskKnock.Plan, frame: Int)?
    private var hidden: Set<TokenKey> = []
    private var iconRevision = 0
    private var drawnRevision = 0
    private var selectionRevision = -1
    private var hoveredPile: PileID?

    /// Hysteresis of the drawn position (art px).
    static let hysteresis: Float = 0.75

    init(hub: PhysicsHub) {
        self.hub = hub
        root.addChild(hub.world.root)
        root.addChild(hub.tosses.root)
        root.addChild(hub.tosses.shadows)
    }

    var context: SceneContext { hub.context }

    // MARK: State

    func layout(_ layout: SceneLayout) {
        snapped.removeAll()
        refresh(force: true)
    }

    func apply(_ s: DeskState) {
        hub.apply(s)
        refresh()
    }

    /// A real icon arrived for `key`.
    func iconChanged() {
        iconRevision += 1
        refresh()
    }

    /// The pile's tokens on show (not in hand, not in the air), top first.
    private func visibleKeys(_ id: PileID) -> [TokenKey] {
        guard let s = hub.state else { return [] }
        return s.tokens.members(of: id).reversed().filter { !hidden.contains($0) }
    }

    /// Redraws every pile at its body's position.
    func refresh(force: Bool = false) {
        hidden = hub.hiddenKeys
        let world = hub.world
        let rebuild = force || drawnRevision != iconRevision
        drawnRevision = iconRevision
        let selection = context.selection
        selectionRevision = selection.revision
        var keep = Set<PileID>()
        for id in hub.bodies.ids {
            guard let p = world.position(of: id), p.isFinite else { continue }
            let keys = visibleKeys(id)
            guard !keys.isEmpty else { continue }
            keep.insert(id)
            let lift = hops.map { $0.plan.pileHops[id]?.offset(atFrame: $0.frame) ?? 0 } ?? 0
            let selected = keys.allSatisfy(selection.contains)
            var entry = shown[id]
            if entry == nil || rebuild || entry!.keys != keys || entry!.lift != lift || entry!.selected != selected {
                let stack = Self.stack(keys, lift: lift, selected: selected, context: context)
                let node = entry?.node ?? SKSpriteNode()
                if node.parent == nil { root.addChild(node) }
                node.texture = TextureFactory.texture(stack.image)
                entry = Shown(keys: keys, lift: lift, selected: selected, stack: stack, base: entry?.base ?? .zero,
                              node: node, d: p.y)
                entry!.base = ArtPoint(Int.min, Int.min)
            }
            let base = snap(id, hub.canvas(plane: p))
            if entry!.base != base || entry!.d != p.y {
                entry!.base = base
                entry!.d = p.y
                let image = entry!.stack.image
                let origin = ArtPoint(base.x - entry!.stack.base.x, base.y - entry!.stack.base.y)
                context.space.place(entry!.node, at: ArtRect(origin: origin, size: image.size))
                entry!.node.zPosition = Self.z(d: p.y)
            }
            shown[id] = entry
        }
        for (id, e) in shown where !keep.contains(id) {
            e.node.removeFromParent()
            shown[id] = nil
            snapped[id] = nil
        }
    }

    /// The draw order of something standing at depth `d` on the desk: in front of the desk-front props' sprites,
    /// nearer the front on top (the pen cup uses it too).
    static func z(d: Float) -> CGFloat {
        CGFloat(RoomLayer.deskFront.rawValue * 1000 + 500) + CGFloat(min(max(128 - d, 0), 200))
    }

    static func stack(_ keys: [TokenKey], lift: Int, selected: Bool = false, context: SceneContext) -> PileArt.Stack {
        let icons = keys.prefix(PileArt.maxIcons).compactMap { k in
            context.state?.tokens.meta(of: k).map { TokenArt.icon(k, $0, context) }
        }
        return PileArt.stack(Array(icons), count: keys.count, shadow: .oak3, lift: lift, selected: selected)
    }

    /// `p` (canvas) as whole px, moving only once it is more than `hysteresis` away from where it is drawn.
    private func snap(_ id: PileID, _ p: SIMD2<Float>) -> ArtPoint {
        let target = ArtPoint(Int(p.x.rounded()), Int(p.y.rounded()))
        guard var s = snapped[id] else {
            snapped[id] = target
            return target
        }
        if abs(p.x - Float(s.x)) > Self.hysteresis { s.x = target.x }
        if abs(p.y - Float(s.y)) > Self.hysteresis { s.y = target.y }
        snapped[id] = s
        return s
    }

    // MARK: Hits

    /// Piles front to back.
    private var frontToBack: [(id: PileID, e: Shown)] {
        shown.map { ($0.key, $0.value) }.sorted { $0.e.d != $1.e.d ? $0.e.d < $1.e.d : $0.id < $1.id }
    }

    /// The pile under canvas pixel `p`.
    func pile(at p: ArtPoint) -> PileID? {
        for (id, e) in frontToBack {
            let origin = ArtPoint(e.base.x - e.stack.base.x, e.base.y - e.stack.base.y)
            if e.stack.hitMask.pixel(p.x - origin.x, p.y - origin.y).a != 0 { return id }
        }
        return nil
    }

    /// The canvas rect of a token's icon in its pile (the front icon's for tokens deeper than three).
    func iconRect(of key: TokenKey) -> ArtRect? {
        for (_, e) in shown {
            guard let i = e.keys.firstIndex(of: key) else { continue }
            let o = e.stack.iconOrigins[min(i, e.stack.iconOrigins.count - 1)]
            let origin = ArtPoint(e.base.x - e.stack.base.x, e.base.y - e.stack.base.y)
            return ArtRect(origin.x + o.x, origin.y + o.y, 16, 16)
        }
        return nil
    }

    func hitTest(_ p: ArtPoint) -> Hit? {
        guard let id = pile(at: p), let e = shown[id] else { return nil }
        let origin = ArtPoint(e.base.x - e.stack.base.x, e.base.y - e.stack.base.y)
        return Hit(element: self.id, part: "pile.\(id.raw)", rect: ArtRect(origin: origin, size: e.stack.image.size),
                   token: e.keys.first)
    }

    private func pileID(_ hit: Hit) -> PileID? {
        guard let part = hit.part, part.hasPrefix("pile.") else { return nil }
        return PileID(String(part.dropFirst(5)))
    }

    func hover(_ hit: Hit?) -> Bool {
        hoveredPile = hit.flatMap(pileID)
        return false
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        guard let id = pileID(hit), let e = shown[id] else { return .standard }
        let origin = ArtPoint(e.base.x - e.stack.base.x, e.base.y - e.stack.base.y)
        return .image(TokenArt.hoverRing(e.stack.hitMask), at: ArtPoint(origin.x - 2, origin.y - 2))
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        guard let id = pileID(hit), let e = shown[id], let s = hub.state else { return nil }
        let metas = e.keys.compactMap { s.tokens.meta(of: $0) }
        guard let top = metas.first else { return nil }
        var spec: TooltipSpec
        if metas.count == 1 {
            spec = TooltipSpec(title: top.displayName, detail: TokenArt.detail(top), anchor: hit.rect)
        } else {
            let names = metas.prefix(3).map(\.displayName).joined(separator: ", ")
            spec = TooltipSpec(title: "\(metas.count) items", detail: metas.count > 3 ? names + "…" : names, anchor: hit.rect)
        }
        spec.prefersAbove = true
        return spec
    }

    // MARK: Gestures

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard let id = pileID(hit), let e = shown[id] else { return .pass }
        let selection = context.selection
        let keys = Set(e.keys)
        switch gesture {
        case let .press(_, mods):
            if mods.contains(.command) || mods.contains(.shift) {
                if keys.isSubset(of: selection.keys), mods.contains(.command) {
                    selection.set(selection.keys.subtracting(keys))
                } else {
                    selection.set(selection.keys.union(keys), primary: e.keys.first)
                }
            } else if !keys.isSubset(of: selection.keys) {
                selection.set(keys, primary: e.keys.first)
            }
            context.screen?.refreshIfSelectionChanged()
            return .handled
        case let .click(_, mods, count):
            if count == 2 {
                context.dispatch(.requestOpen(e.keys))
            } else if count == 1, mods.isEmpty {
                selection.set(keys, primary: e.keys.first)
                context.screen?.refreshIfSelectionChanged()
            }
            return .handled
        case let .dragBegan(from, at, _):
            let origin = ArtPoint(e.base.x - e.stack.base.x, e.base.y - e.stack.base.y)
            let origins = e.keys.indices.map { i -> ArtPoint in
                let o = e.stack.iconOrigins[min(i, e.stack.iconOrigins.count - 1)]
                return ArtPoint(origin.x + o.x, origin.y + o.y)
            }
            hub.bodies.thaw(near: hub.world.position(of: id) ?? .zero)
            let session = CarrySession(keys: e.keys, origins: origins, grab: from, context: context)
            session.moved(to: at, mods: [])
            refresh()
            return .drag(session)
        case .scroll, .cancelPress:
            return .pass
        }
    }

    /// The bare desk top takes drops (where it is not the back strip's furniture): the pile the point is on, or a
    /// new one. The hub decides where they land.
    func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? {
        guard let s = hub.state, context.layout.rect(CoreLayout.deskTop).contains(p) else { return nil }
        let q = hub.plane(SIMD2(Float(p.x) + 0.5, Float(p.y) + 0.5))
        let desk = DeskPlanePhysics.desk
        guard q.x >= desk.x, q.x <= desk.x + desk.width, q.y >= desk.d, q.y <= desk.d + desk.depth else { return nil }
        let inFurniture = DeskPlanePhysics.footprints.values.contains { f in
            q.x >= f.x && q.x < f.x + f.width && q.y >= f.d && q.y < f.d + f.depth
        }
        guard !inFurniture else { return nil }
        if let id = pile(at: p) { return .accept(.desk(pile: id, order: s.tokens.members(of: id).count)) }
        return .accept(.desk(pile: s.makePileID(), order: 0))
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        guard let id = pileID(hit), let e = shown[id], let s = hub.state else { return nil }
        let selection = context.selection
        if !Set(e.keys).isSubset(of: selection.keys) { selection.set(Set(e.keys), primary: e.keys.first) }
        selection.restrict(to: shownTokensAll())
        context.screen?.refreshIfSelectionChanged()
        return MenuSpec.token(selection.sorted, s)
    }

    /// Every token the room's desk-plane elements show (the selection may span the screen, piles and the floor).
    private func shownTokensAll() -> Set<TokenKey> {
        shownTokens.union(hub.floor.shownTokens).union(context.screen?.shownTokens ?? [])
    }

    var shownTokens: Set<TokenKey> { Set(shown.values.flatMap(\.keys)) }

    func accessibilityItems() -> [AXItem] {
        guard let s = hub.state else { return [] }
        return frontToBack.map { id, e in
            let names = e.keys.compactMap { s.tokens.meta(of: $0)?.displayName }
            let origin = ArtPoint(e.base.x - e.stack.base.x, e.base.y - e.stack.base.y)
            return AXItem(id: "pile.\(id.raw)", label: "Pile: " + names.joined(separator: ", "), role: .group,
                          frame: ArtRect(origin: origin, size: e.stack.image.size), token: e.keys.first)
        }
    }

    // MARK: Frames

    var needsFrames: Bool { hub.needsFrames || hops != nil }

    func step(_ dt: Double) {
        hub.step(dt)
        if var h = hops {
            h.frame += 1
            hops = h.frame >= h.plan.frames ? nil : h
        }
        if hidden != hub.hiddenKeys || hops != nil || hub.bodies.isMoving || selectionRevision != context.selection.revision {
            refresh()
        }
    }

    func settle() {
        hops = nil
        hub.settle()
        refresh()
    }

    func knock(_ plan: DeskKnock.Plan) {
        hops = (plan, 0)
        refresh()
    }
}
