import DeskCore
import SpriteKit

/// Tokens on the floor (DESIGN §2.2 E11): 16×16 icons standing on the front floor line, centred on their stored x
/// (`Location.floor(x:)`, `FloorLine`), no physics. Tokens sharing an x (a stack that landed together, balls that did
/// not fit side by side) stand as one floor stack, drawn like a desk pile (`PileArt.stack`: up to three icons and a
/// count tag over the icon's cast shadow). They draw in front of the under-desk furniture they never stand in front
/// of, behind the chair. Hover rings and tooltips like the screen's tokens; a press selects the stack (⌘ toggles), a
/// double-click opens it, a drag carries it back up (`CarrySession`), right-click is the token menu. A knock hops them
/// 1 px.
final class FloorElement: DeskElement, Knockable {
    let id = "floor"
    let root = SKNode()
    unowned let hub: PhysicsHub

    private struct Shown {
        /// Front first.
        var keys: [TokenKey]
        var stack: PileArt.Stack
        /// Canvas top-left of the stack's image.
        var origin: ArtPoint
        var lift: Int
        var selected: Bool
        var node: SKSpriteNode
    }

    /// Floor stacks by centre x.
    private var shown: [Int: Shown] = [:]
    private var hops: (plan: DeskKnock.Plan, frame: Int)?
    private var hidden: Set<TokenKey> = []
    private var iconRevision = 0
    private var drawnRevision = 0
    private var selectionRevision = -1

    /// Shadow ink on the boards and the rug (one step darker than the boards).
    static let shadowInk = Ink.oak1

    init(hub: PhysicsHub) {
        self.hub = hub
    }

    var context: SceneContext { hub.context }

    func layout(_ layout: SceneLayout) {
        refresh(force: true)
    }

    func apply(_ s: DeskState) {
        refresh()
    }

    func iconChanged() {
        iconRevision += 1
        refresh()
    }

    /// The floor's z: over the cabinet and the basket, under the chair and the fx.
    static let z = CGFloat(RoomLayer.underDesk.rawValue * 1000 + 600)

    /// The floor's tokens on show, by centre x, front first (the last by key order in front).
    private func stacks(_ s: DeskState) -> [Int: [TokenKey]] {
        var out: [Int: [TokenKey]] = [:]
        for key in s.tokens.keys(where: { if case .floor = $0 { true } else { false } }) where !hidden.contains(key) {
            guard case let .floor(x)? = s.tokens.location(of: key) else { continue }
            out[x, default: []].insert(key, at: 0)
        }
        return out
    }

    func refresh(force: Bool = false) {
        hidden = hub.hiddenKeys
        guard let s = hub.state else { return }
        let rebuild = force || drawnRevision != iconRevision
        drawnRevision = iconRevision
        selectionRevision = context.selection.revision
        let all = stacks(s)
        let layout = context.layout
        for (x, keys) in all {
            let lift = hops.map { h in keys.lazy.compactMap { h.plan.floorHops[$0] }.first?.offset(atFrame: h.frame) ?? 0 } ?? 0
            let selected = keys.allSatisfy(context.selection.contains)
            var e = shown[x]
            if e == nil || rebuild || e!.keys != keys || e!.lift != lift || e!.selected != selected {
                let icons = keys.prefix(PileArt.maxIcons).compactMap { k in s.tokens.meta(of: k).map { TokenArt.icon(k, $0, context) } }
                let stack = PileArt.stack(icons, count: keys.count, shadow: Self.shadowInk, lift: lift, selected: selected)
                let node = e?.node ?? SKSpriteNode()
                if node.parent == nil { root.addChild(node) }
                node.texture = TextureFactory.texture(stack.image)
                e = Shown(keys: keys, stack: stack, origin: ArtPoint(Int.min, 0), lift: lift, selected: selected, node: node)
            }
            let origin = ArtPoint(layout.x(x) - e!.stack.base.x, layout.floorY - e!.stack.base.y)
            if e!.origin != origin {
                e!.origin = origin
                context.space.place(e!.node, at: ArtRect(origin: origin, size: e!.stack.image.size))
            }
            // Left to right, a stack on the right over its left neighbour's shadow.
            e!.node.zPosition = Self.z + CGFloat(x) * 0.001
            shown[x] = e
        }
        for (x, e) in shown where all[x] == nil {
            e.node.removeFromParent()
            shown[x] = nil
        }
    }

    // MARK: Hits

    /// The floor stack under canvas pixel `p` (the rightmost on top).
    private func stackX(at p: ArtPoint) -> Int? {
        for x in shown.keys.sorted(by: >) {
            let e = shown[x]!
            if e.stack.hitMask.pixel(p.x - e.origin.x, p.y - e.origin.y).a != 0 { return x }
        }
        return nil
    }

    /// The token at `p`: its stack's front token.
    func token(at p: ArtPoint) -> TokenKey? {
        stackX(at: p).flatMap { shown[$0]?.keys.first }
    }

    /// The canvas rect of a token's icon (the front icon's for tokens deeper than three).
    func iconRect(of key: TokenKey) -> ArtRect? {
        for e in shown.values {
            guard let i = e.keys.firstIndex(of: key) else { continue }
            let o = e.stack.iconOrigins[min(i, e.stack.iconOrigins.count - 1)]
            return ArtRect(e.origin.x + o.x, e.origin.y + o.y, 16, 16)
        }
        return nil
    }

    /// The canvas rect of the stack holding `key`.
    private func stackRect(_ e: Shown) -> ArtRect { ArtRect(origin: e.origin, size: e.stack.image.size) }

    func hitTest(_ p: ArtPoint) -> Hit? {
        guard let x = stackX(at: p), let e = shown[x], let key = e.keys.first else { return nil }
        return Hit(element: id, part: "floor.\(x)", rect: iconRect(of: key) ?? stackRect(e), token: key)
    }

    private func stack(_ hit: Hit) -> Shown? {
        guard let part = hit.part, part.hasPrefix("floor."), let x = Int(part.dropFirst(6)) else { return nil }
        return shown[x]
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        guard let e = stack(hit) else { return .standard }
        return .image(TokenArt.hoverRing(e.stack.hitMask), at: ArtPoint(e.origin.x - 2, e.origin.y - 2))
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        guard let e = stack(hit), let s = hub.state else { return nil }
        let metas = e.keys.compactMap { s.tokens.meta(of: $0) }
        guard let top = metas.first else { return nil }
        var spec: TooltipSpec
        if metas.count == 1 {
            spec = TooltipSpec(title: top.displayName, detail: TokenArt.detail(top), anchor: hit.rect)
        } else {
            let names = metas.prefix(3).map(\.displayName).joined(separator: ", ")
            spec = TooltipSpec(title: "\(metas.count) items", detail: metas.count > 3 ? names + "…" : names,
                               anchor: stackRect(e))
        }
        spec.prefersAbove = true
        return spec
    }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard let e = stack(hit), let s = hub.state, e.keys.allSatisfy(s.tokens.contains) else { return .pass }
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
                let open = keys.isSubset(of: selection.keys) ? selection.sorted.filter(shownTokens.contains) : e.keys
                context.dispatch(.requestOpen(open))
            } else if count == 1, mods.isEmpty {
                selection.set(keys, primary: e.keys.first)
                context.screen?.refreshIfSelectionChanged()
            }
            return .handled
        case let .dragBegan(from, at, _):
            if !keys.isSubset(of: selection.keys) { selection.set(keys, primary: e.keys.first) }
            context.screen?.refreshIfSelectionChanged()
            // This stack (front first), then the other floor tokens selected with it.
            let others = selection.sorted.filter { !keys.contains($0) && shownTokens.contains($0) }
            let carried = e.keys + others
            let origins = carried.compactMap { iconRect(of: $0)?.origin }
            guard origins.count == carried.count else { return .pass }
            let session = CarrySession(keys: carried, origins: origins, grab: from, context: context)
            session.moved(to: at, mods: [])
            refresh()
            return .drag(session)
        case .scroll, .cancelPress:
            return .pass
        }
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        guard let e = stack(hit), let s = hub.state else { return nil }
        let selection = context.selection
        if !Set(e.keys).isSubset(of: selection.keys) { selection.set(Set(e.keys), primary: e.keys.first) }
        context.screen?.refreshIfSelectionChanged()
        return MenuSpec.token(selection.sorted.filter { s.tokens.contains($0) }, s)
    }

    var shownTokens: Set<TokenKey> { Set(shown.values.flatMap(\.keys)) }

    func accessibilityItems() -> [AXItem] {
        guard let s = hub.state else { return [] }
        return shown.keys.sorted().compactMap { x in
            let e = shown[x]!
            let names = e.keys.compactMap { s.tokens.meta(of: $0)?.displayName }
            guard let first = e.keys.first else { return nil }
            if e.keys.count == 1 {
                return AXItem(id: "floor.\(first.inode)", label: names.first ?? "", role: .token,
                              frame: iconRect(of: first) ?? stackRect(e), token: first)
            }
            return AXItem(id: "floor.\(x)", label: "Floor: " + names.joined(separator: ", "), role: .group,
                          frame: stackRect(e), token: first)
        }
    }

    // MARK: Frames

    var needsFrames: Bool { hops != nil }

    func step(_ dt: Double) {
        if var h = hops {
            h.frame += 1
            hops = h.frame >= h.plan.frames ? nil : h
            refresh()
        } else if hidden != hub.hiddenKeys || selectionRevision != context.selection.revision {
            refresh()
        }
    }

    func settle() {
        hops = nil
        refresh()
    }

    func knock(_ plan: DeskKnock.Plan) {
        guard !plan.floorHops.isEmpty else { return }
        hops = (plan, 0)
    }
}
