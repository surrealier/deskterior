import DeskCore
import SpriteKit

/// Tokens on the floor (DESIGN §2.2 E11): 16×16 icons standing on the front floor line, centred on their stored x
/// (`Location.floor(x:)`, `FloorLine`), no physics. They draw in front of the under-desk furniture they never stand
/// in front of, behind the chair. Hover rings and tooltips like the screen's tokens; a press selects (⌘ toggles), a
/// double-click opens, a drag carries them back up (`CarrySession`), right-click is the token menu. A knock hops
/// them 1 px.
final class FloorElement: DeskElement, Knockable {
    let id = "floor"
    let root = SKNode()
    unowned let hub: PhysicsHub

    private struct Shown {
        var image: PixelBuffer
        var icon: PixelBuffer
        var origin: ArtPoint
        var lift: Int
        var selected: Bool
        var node: SKSpriteNode
    }

    /// The drawn image: 18×20, the icon's bottom row on the floor line (image row 18) over a 2-row shadow.
    static let imageSize = ArtSize(18, 20)

    private var shown: [TokenKey: Shown] = [:]
    /// Floor tokens in draw order (later on top).
    private var order: [TokenKey] = []
    private var hops: (plan: DeskKnock.Plan, frame: Int)?
    private var hidden: Set<TokenKey> = []
    private var iconRevision = 0
    private var drawnRevision = 0
    private var selectionRevision = -1

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

    /// The token's icon rect (canvas px) on the floor at core x `x` (its centre), standing on the floor line.
    func iconRect(x: Int, lift: Int = 0) -> ArtRect {
        let layout = context.layout
        return ArtRect(layout.x(x) - FloorLine.tokenWidth / 2, layout.floorY - 16 - lift, 16, 16)
    }

    func refresh(force: Bool = false) {
        hidden = hub.hiddenKeys
        guard let s = hub.state else { return }
        let rebuild = force || drawnRevision != iconRevision
        drawnRevision = iconRevision
        selectionRevision = context.selection.revision
        let tokens = s.tokens.keys { if case .floor = $0 { true } else { false } }.filter { !hidden.contains($0) }
        var keep = Set<TokenKey>()
        for (i, key) in tokens.enumerated() {
            guard case let .floor(x)? = s.tokens.location(of: key), let meta = s.tokens.meta(of: key) else { continue }
            keep.insert(key)
            let lift = hops.map { $0.plan.floorHops[key]?.offset(atFrame: $0.frame) ?? 0 } ?? 0
            let rect = iconRect(x: x)
            var e = shown[key]
            let selected = context.selection.contains(key)
            if e == nil || rebuild || e!.lift != lift || e!.selected != selected {
                let icon = TokenArt.icon(key, meta, context)
                var c = PixelCanvas(width: Self.imageSize.w, height: Self.imageSize.h)
                // A contact shadow on the boards (one step darker), then the icon, hopping `lift` px off it.
                c.hline(x: 2, y: 18, length: 14, .oak1)
                c.hline(x: 4, y: 19, length: 10, .oak1)
                if selected {
                    c.roundedRectFill(ArtRect(0, 2 - lift, 18, 18), radius: 3, .blue0)
                    c.roundedRectFill(ArtRect(1, 3 - lift, 16, 16), radius: 2, Role.selection)
                }
                c.blit(icon, at: ArtPoint(1, 3 - lift))
                let node = e?.node ?? SKSpriteNode()
                if node.parent == nil { root.addChild(node) }
                node.texture = TextureFactory.texture(c.buffer)
                e = Shown(image: c.buffer, icon: icon, origin: ArtPoint(Int.min, 0), lift: lift, selected: selected, node: node)
            }
            let origin = ArtPoint(rect.x - 1, rect.y - 3)
            if e!.origin != origin {
                e!.origin = origin
                context.space.place(e!.node, at: ArtRect(origin: origin, size: e!.image.size))
            }
            e!.node.zPosition = Self.z + CGFloat(i) * 0.01
            shown[key] = e
        }
        for (key, e) in shown where !keep.contains(key) {
            e.node.removeFromParent()
            shown[key] = nil
        }
        order = tokens.filter(keep.contains)
    }

    // MARK: Hits

    func token(at p: ArtPoint) -> TokenKey? {
        for key in order.reversed() {
            guard let r = iconRect(of: key), let e = shown[key] else { continue }
            if e.icon.pixel(p.x - r.x, p.y - r.y).a != 0 { return key }
        }
        return nil
    }

    func iconRect(of key: TokenKey) -> ArtRect? {
        guard let e = shown[key] else { return nil }
        return ArtRect(e.origin.x + 1, e.origin.y + 3 - e.lift, 16, 16)
    }

    func hitTest(_ p: ArtPoint) -> Hit? {
        guard let key = token(at: p), let r = iconRect(of: key) else { return nil }
        return Hit(element: id, part: "token", rect: r, token: key)
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        guard let key = hit.token, let meta = hub.state?.tokens.meta(of: key) else { return .standard }
        return .image(TokenArt.hoverRing(TokenArt.icon(key, meta, context)), at: ArtPoint(hit.rect.x - 2, hit.rect.y - 2))
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        guard let key = hit.token, let meta = hub.state?.tokens.meta(of: key) else { return nil }
        var spec = TooltipSpec(title: meta.displayName, detail: TokenArt.detail(meta), anchor: hit.rect)
        spec.prefersAbove = true
        return spec
    }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard let key = hit.token, let s = hub.state, s.tokens.contains(key) else { return .pass }
        let selection = context.selection
        switch gesture {
        case let .press(_, mods):
            if mods.contains(.command) || mods.contains(.shift) {
                selection.click(key, mods: mods)
            } else if !selection.contains(key) {
                selection.select(key)
            }
            context.screen?.refreshIfSelectionChanged()
            return .handled
        case let .click(_, mods, count):
            if count == 2 {
                let keys = selection.contains(key) ? selection.sorted.filter(shownTokens.contains) : [key]
                context.dispatch(.requestOpen(keys))
            } else if count == 1, mods.isEmpty {
                selection.select(key)
                context.screen?.refreshIfSelectionChanged()
            }
            return .handled
        case let .dragBegan(from, at, _):
            if !selection.contains(key) { selection.select(key) }
            context.screen?.refreshIfSelectionChanged()
            var keys = [key] + selection.sorted.filter { $0 != key && shown[$0] != nil }
            keys = keys.filter { iconRect(of: $0) != nil }
            let origins = keys.compactMap { iconRect(of: $0)?.origin }
            let session = CarrySession(keys: keys, origins: origins, grab: from, context: context)
            session.moved(to: at, mods: [])
            refresh()
            return .drag(session)
        case .scroll, .cancelPress:
            return .pass
        }
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        guard let key = hit.token, let s = hub.state else { return nil }
        let selection = context.selection
        if !selection.contains(key) { selection.select(key) }
        context.screen?.refreshIfSelectionChanged()
        return MenuSpec.token(selection.sorted.filter { s.tokens.contains($0) }, s)
    }

    var shownTokens: Set<TokenKey> { Set(shown.keys) }

    func accessibilityItems() -> [AXItem] {
        guard let s = hub.state else { return [] }
        return order.compactMap { key in
            guard let r = iconRect(of: key), let meta = s.tokens.meta(of: key) else { return nil }
            return AXItem(id: "floor.\(key.inode)", label: meta.displayName, role: .token, frame: r, token: key)
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
