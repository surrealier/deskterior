import DeskCore
import SpriteKit

/// The monitor riser (DESIGN §2.2 E3): two mini-drawers and the cubby, drawn here in place of the room's riser
/// sprites once a model arrives.
///
/// - **Drawers** (`DrawerUnit`): drag the front (or its pull) toward the viewer to open, back to shut — a flick shut
///   slams (a puff, a 2-frame shake and `onSlam`, the desk-knock hook); a click opens one less than half open and
///   closes one more than half; a scroll over it peeks; a drop on the shut front chomps the tokens in; a carry
///   resting on the front for 0.6 s springs it open. An overfull drawer rests ajar with paper poking out; at its
///   hard cap drops bonk ("That's full."). Open, its contents are selectable 12-px minis at their jostled rows.
/// - **Cubby**: an open shelf; drops go in; its contents are dim silhouettes you can hover (name), select, open
///   and drag out.
/// - Right-click a drawer or the cubby for its container menu; a mini for the token menu.
/// - **Sealed** (Erratum 30): while the riser drawers are put away the riser stays, a plain monitor stand drawn by
///   `StorageArt.riser(sealed: true)`: no drawers, the cubby closed. It stays routed: the whole riser is one part
///   (`riser.sealed`), its menu brings the drawers back (`MenuSpec.sealedRiser`), and drops on it bonk ("The drawers
///   are put away.").
final class RiserElement: ContainerElement, DeskElement {
    let id = "riser"
    let units: [DrawerUnit] = [DrawerUnit(.riserLeft, contentInset: 2), DrawerUnit(.riserRight, contentInset: 2)]
    private(set) var cubbyMembers: [TokenKey] = []
    private var cubbyItems: [InteriorRaster.Item] = []
    private let bodyNode = SKSpriteNode()
    private let drawerNodes = [SKSpriteNode(), SKSpriteNode()]
    private var bodyImage = StorageArt.riser().image
    private var bodyLook: CubbyLook?
    private var drawerLooks: [DrawerLook?] = [nil, nil]
    /// A drawer slammed shut at this speed (px/s): the desk knock's trigger (M7).
    var onSlam: ((ContainerID, Float) -> Void)?

    override init(context: SceneContext) {
        super.init(context: context)
        for n in [bodyNode] + drawerNodes {
            n.isHidden = true
            root.addChild(n)
        }
    }

    override var drawnPlacements: [String] { ["riser", "riser.drawerL", "riser.drawerR"] }

    static let anchorNames: [ContainerID: String] = [.riserLeft: "riser.drawerL", .riserRight: "riser.drawerR"]
    /// The sealed riser's one part.
    static let sealedPart = "riser.sealed"

    // MARK: Geometry

    var riserRect: ArtRect { context.layout.rect(CoreLayout.riser) }
    var cubbyRect: ArtRect { context.layout.rect(CoreLayout.riserCubby) }

    // MARK: tidy (0.3.0)
    /// The drawers are put away: the riser is a sealed stand.
    var isSealed: Bool { state?.isAway(.riserLeft) == true }

    func unit(_ id: ContainerID) -> DrawerUnit? { units.first { $0.id == id } }

    /// Each cubby member's drawn rect (canvas px).
    func cubbyRects() -> [ArtRect] {
        let o = cubbyRect.origin
        let clip = cubbyRect
        return InteriorRaster.cubbyRects(count: cubbyMembers.count).map { $0.offsetBy(o.x, o.y).intersection(clip) }
    }

    /// The live rect of a riser anchor (the pulls and fronts follow the drawers out); none while sealed.
    func liveAnchor(_ name: String) -> ArtRect? {
        guard !isSealed else { return nil }
        for u in units {
            let base = Self.anchorNames[u.id]!
            switch name {
            case base, base + ".front": return u.front
            case base + ".handle": return u.handle
            case base + ".interior": return u.interior
            default: continue
            }
        }
        return nil
    }

    /// Where `key` shows as a mini (the part of it that answers a click, canvas px), if it does.
    func miniRect(of key: TokenKey) -> ArtRect? {
        guard !isSealed else { return nil }
        var drawn: ArtRect?
        for u in units where u.showsMinis {
            if let i = u.members.firstIndex(of: key) { drawn = u.miniRects()[i].intersection(u.contentClip) }
        }
        if let i = cubbyMembers.firstIndex(of: key) { drawn = cubbyRects()[i] }
        guard let drawn, !drawn.isEmpty else { return nil }
        return Self.pickable(drawn, key: key) { [unowned self] in hitTest($0)?.token }
    }

    // MARK: DeskElement

    func layout(_ layout: SceneLayout) {
        for u in units {
            let core = u.id == .riserLeft ? CoreLayout.riserDrawerL : CoreLayout.riserDrawerR
            u.closedFront = layout.rect(core)
            u.closedHandle = layout.rect(Anchors.handle(of: core, width: 12))
        }
        bodyLook = nil
        drawerLooks = [nil, nil]
        hidePlaced()
        render()
    }

    func apply(_ s: DeskState) {
        adopt(s)
        for u in units { u.sync(s) }
        cubbyMembers = s.tokens.members(of: .riserCubby)
        cubbyItems = InteriorRaster.items(.riserCubby, in: s)
        render()
    }

    func hitTest(_ p: ArtPoint) -> Hit? {
        if isSealed {
            let r = riserRect
            guard r.contains(p), bodyImage.pixel(p.x - r.x, p.y - r.y).a != 0 else { return nil }
            return Hit(element: id, part: Self.sealedPart, rect: r)
        }
        let hidden = carried
        for u in units where u.area.contains(p) {
            let name = Self.anchorNames[u.id]!
            if let m = u.mini(at: p, except: hidden) {
                return Hit(element: id, part: "token", rect: m.rect, token: m.key)
            }
            if u.handle.contains(p) { return Hit(element: id, part: name + ".handle", rect: u.handle) }
            if u.front.contains(p) { return Hit(element: id, part: name, rect: u.front) }
            return Hit(element: id, part: name + ".interior", rect: u.interior)
        }
        if cubbyRect.contains(p) {
            let rects = cubbyRects()
            // The plain order the cubby draws them in, reversed (as in the drawers, the selected and hovered ones
            // drawn on top don't cover their neighbours' strips).
            let order = InteriorRaster.drawOrder(cubbyMembers.count, open: true, marks: .none) {
                InteriorRaster.cubbyRects(count: cubbyMembers.count)[$0].maxY
            }.reversed()
            for i in order where !hidden.contains(cubbyMembers[i]) && rects[i].contains(p) {
                return Hit(element: id, part: "token", rect: rects[i], token: cubbyMembers[i])
            }
            return Hit(element: id, part: "riser.cubby", rect: cubbyRect)
        }
        let r = riserRect
        guard r.contains(p), bodyImage.pixel(p.x - r.x, p.y - r.y).a != 0 else { return nil }
        return Hit(element: id, part: nil, rect: r)
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        if let key = hit.token, let meta = state?.tokens.meta(of: key) {
            let icon = KindIcons.icon(InteriorRaster.iconKind(meta.kind), size: InteriorRaster.miniSize).image
            if let i = cubbyMembers.firstIndex(of: key) {
                let r = context.layout.rect(CoreLayout.riserCubby)
                let rect = InteriorRaster.cubbyRects(count: cubbyMembers.count)[i].offsetBy(r.x, r.y)
                return Self.miniRing(icon, at: rect.origin, clip: r)
            }
            for u in units {
                guard let i = u.members.firstIndex(of: key) else { continue }
                return Self.miniRing(icon, at: u.miniRects()[i].origin, clip: u.contentClip)
            }
            return .none
        }
        guard let part = hit.part, part != Self.sealedPart else { return Self.outline(bodyImage, at: riserRect.origin) }
        if part == "riser.cubby" { return Self.ring(around: cubbyRect) }
        if part.hasSuffix(".interior") { return .none }
        let u = units.first { part.hasPrefix(Self.anchorNames[$0.id]!) }
        return u.map { Self.ring(around: $0.handle) } ?? .none
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        if let key = hit.token { return miniTooltip(key, anchor: hit.rect) }
        guard let s = state else { return TooltipSpec(title: "Monitor Riser", anchor: hit.rect) }
        guard let part = hit.part, part != Self.sealedPart else {
            return TooltipSpec(title: "Monitor Riser", anchor: riserRect)
        }
        let id: ContainerID = part == "riser.cubby"
            ? .riserCubby : (part.hasPrefix("riser.drawerL") ? .riserLeft : .riserRight)
        let detail = Self.countText(s.tokens.count(in: id), cap: id.spec)
        return TooltipSpec(title: MenuSpec.containerTitle(id), detail: detail, anchor: hit.rect)
    }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard state != nil else { return .pass }
        if hit.part == Self.sealedPart {
            switch gesture {
            case .press, .cancelPress: return .handled
            case .click, .dragBegan, .scroll: return .pass
            }
        }
        if let key = hit.token {
            if case .scroll = gesture, let u = units.first(where: { $0.members.contains(key) }) {
                u.scroll(gesture.scrollDY)
                return .handled
            }
            return handleMini(gesture, key: key, shown: shownTokens) { [unowned self] k in
                miniRect(of: k).map(Self.carryOrigin(over:))
            }
        }
        guard let part = hit.part, let u = units.first(where: { part.hasPrefix(Self.anchorNames[$0.id]!) }) else {
            return .pass
        }
        let isInterior = part.hasSuffix(".interior")
        switch gesture {
        case .press, .cancelPress:
            return .handled
        case let .click(_, _, count):
            if isInterior { return .pass }
            if count == 1 { u.toggle() }
            return .handled
        case let .dragBegan(from, at, mods):
            if isInterior { return .pass }
            let pull = DrawerPull(unit: u, from: from)
            pull.moved(to: at, mods: mods)
            return .drag(pull)
        case let .scroll(_, delta, _):
            u.scroll(delta.y)
            return .handled
        }
    }

    func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? {
        guard let s = state else { return nil }
        if isSealed { return hitTest(p) == nil ? nil : .bonk(.drawersPutAway) }
        for u in units where u.area.contains(p) {
            return u.fits(tokens) ? .accept(.container(u.id, order: u.members.count)) : .bonk(.containerFull)
        }
        if cubbyRect.contains(p) {
            let movers = Set(tokens)
            let staying = cubbyMembers.filter { !movers.contains($0) }.count
            return staying + movers.count <= ContainerID.riserCubby.spec.hardCap
                ? .accept(.container(.riserCubby, order: s.tokens.count(in: .riserCubby))) : .bonk(.containerFull)
        }
        return nil
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        guard let s = state else { return nil }
        if hit.part == Self.sealedPart { return MenuSpec.sealedRiser(s, context.menuContextNow) }
        if let key = hit.token { return miniMenu(key) }
        guard let part = hit.part else { return nil }
        if part == "riser.cubby" { return MenuSpec.container(.riserCubby, s) }
        return units.first { part.hasPrefix(Self.anchorNames[$0.id]!) }.map { MenuSpec.container($0.id, s) }
    }

    var shownTokens: Set<TokenKey> {
        guard !isSealed else { return [] }
        var out = Set(cubbyMembers)
        for u in units where u.showsMinis { out.formUnion(u.members) }
        return out
    }

    func accessibilityItems() -> [AXItem] {
        guard let s = state else { return [] }
        if isSealed { return [AXItem(id: "riser", label: "Monitor Riser", role: .group, frame: riserRect)] }
        var items: [AXItem] = units.map { u in
            AXItem(id: Self.anchorNames[u.id]!, label: Self.containerLabel(u.id, count: u.members.count),
                   role: .container, frame: u.front)
        }
        items.append(AXItem(id: "riser.cubby", label: Self.containerLabel(.riserCubby, count: cubbyMembers.count),
                            role: .container, frame: cubbyRect))
        for key in shownTokens.sorted() {
            guard let r = miniRect(of: key), let meta = s.tokens.meta(of: key) else { continue }
            items.append(AXItem(id: "token.\(key.inode)", label: meta.displayName, role: .token, frame: r, token: key))
        }
        return items
    }

    // MARK: Frames

    var needsFrames: Bool { units.contains { $0.needsFrames } || pulse != nil }

    func step(_ dt: Double) {
        let carry = isSealed ? nil : carryInHand
        for u in units {
            _ = u.carry(at: carry?.point, accepts: carry.map { u.fits($0.keys) } ?? false, dt: dt)
            handle(u.step(dt), of: u)
        }
        _ = stepPulse(dt, shown: shownTokens)
        if render() { refreshHover() }
    }

    func settle() {
        for u in units { handle(u.settle(), of: u) }
        endPulse(shown: shownTokens)
        render()
    }

    /// Commits rests; a slam puffs, shakes and knocks.
    func handle(_ events: [DrawerSim.Event], of u: DrawerUnit) {
        for e in events {
            switch e {
            case let .settled(p):
                context.dispatch(.drawerSettled(u.id, p))
            case let .slam(speed):
                context.fx.puff(at: ArtPoint(u.front.midX, u.front.maxY + 1))
                context.shake(frames: 2)
                onSlam?(u.id, speed)
            default:
                break
            }
        }
    }

    /// A desk knock's plan (M7 calls this): ajar drawers within reach snap shut, contents hop.
    func knock(_ plan: DeskKnock.Plan) {
        for u in units {
            u.knock(closes: plan.drawerCloses.contains(u.id),
                    jostleStrength: plan.drawerJostle.contains(u.id) ? plan.strength : nil, seed: plan.seed)
        }
    }

    override func selectionChanged() { render() }

    // MARK: Drawing

    /// Redraws what changed: the body (with the cubby's silhouettes) and each drawer at its opening. True when a
    /// drawer moved.
    @discardableResult
    func render() -> Bool {
        guard state != nil else { return false }
        var moved = false
        let space = context.space
        let hidden = carried
        let selected = drawnSelected
        let sealed = isSealed
        let look = sealed
            ? CubbyLook(items: [], marks: .none, sealed: true)
            : CubbyLook(items: cubbyItems, marks: cubbyMarks(hidden: hidden, selected: selected))
        if look != bodyLook {
            bodyLook = look
            bodyImage = sealed
                ? StorageArt.riser(sealed: true).image
                : StorageArt.riser(cubbyContents: InteriorRaster.cubby(cubbyItems, marks: look.marks)).image
            bodyNode.texture = TextureFactory.texture(bodyImage)
            space.place(bodyNode, at: ArtRect(origin: riserRect.origin, size: bodyImage.size))
            bodyNode.zPosition = context.placementZ("riser")
            bodyNode.isHidden = false
        }
        if sealed {
            for node in drawerNodes { node.isHidden = true }
            drawerLooks = [nil, nil]
            return false
        }
        for (i, u) in units.enumerated() {
            let look = u.look(hidden: hidden, selected: selected, raised: raisedKeys, hovered: hoveredKey)
            guard look != drawerLooks[i] else { continue }
            moved = moved || look.p != drawerLooks[i]?.p || look.dx != drawerLooks[i]?.dx
            drawerLooks[i] = look
            let image = InteriorRaster.riserDrawer(u.id, p: look.p, items: look.items, offsets: look.offsets,
                                                   revealed: look.revealed, marks: look.marks).image
            let node = drawerNodes[i]
            node.texture = TextureFactory.texture(image)
            space.place(node, at: ArtRect(origin: u.closedFront.origin + ArtPoint(u.wiggleDX, 0), size: image.size))
            node.zPosition = context.placementZ(Self.anchorNames[u.id]!)
            node.isHidden = false
        }
        return moved
    }

    /// How the cubby draws its members: in hand, selected, raised, hovered.
    func cubbyMarks(hidden: Set<TokenKey>, selected: Set<TokenKey>? = nil) -> InteriorRaster.Marks {
        let sel = selected ?? drawnSelected
        let raised = raisedKeys
        return InteriorRaster.Marks(hidden: Set(cubbyMembers.indices.filter { hidden.contains(cubbyMembers[$0]) }),
                                    selected: Set(cubbyMembers.indices.filter { sel.contains(cubbyMembers[$0]) }),
                                    raised: Set(cubbyMembers.indices.filter { raised.contains(cubbyMembers[$0]) }),
                                    hovered: Set(cubbyMembers.indices.filter { cubbyMembers[$0] == hoveredKey }))
    }

    /// The drawer composite as drawn now (tests, goldens).
    func drawerImage(_ id: ContainerID) -> PixelBuffer? {
        guard let u = unit(id) else { return nil }
        let marks = u.marks(hidden: carried, selected: drawnSelected, raised: raisedKeys, hovered: hoveredKey)
        return InteriorRaster.riserDrawer(u.id, p: u.pixel, items: u.items, offsets: u.jostle.pixelOffsets,
                                          revealed: u.sim.isRevealed, marks: marks).image
    }
}

/// What the cubby shows (redrawn only when it changes); `sealed`: none, the drawers are put away.
struct CubbyLook: Equatable {
    var items: [InteriorRaster.Item]
    var marks: InteriorRaster.Marks
    var sealed = false
}

extension Gesture {
    /// A scroll's vertical delta (0 for other gestures).
    var scrollDY: Float {
        if case let .scroll(_, delta, _) = self { return delta.y }
        return 0
    }
}
