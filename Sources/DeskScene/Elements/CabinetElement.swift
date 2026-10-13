import DeskCore
import SpriteKit

/// The pedestal cabinet under the desk (DESIGN §2.2 E5, Errata 13): three drawers — top and middle hold 12-px
/// minis, the file drawer hangs folders whose tabs carry the names' initials — with the riser drawers' gestures
/// (pull, click, peek, chomp, spring-loading, jam, bonk at the hard cap), drawn here in place of the room's cabinet
/// sprite once a model arrives.
///
/// The drawers are interlocked: opening one shuts the others. The chair blocks them: while it overlaps the fronts
/// by more than 16 px a drawer opens only 3 px (`DrawerSim.cabinetOpenLimit`, re-read from the chair every
/// frame) and running into it thunks — a sparkle, a 1-frame shake — and pushes the chair aside
/// (`RollerSim.pushedByDrawer`), so the next pull works. An open drawer in turn stops the chair rolling in.
final class CabinetElement: ContainerElement, DeskElement {
    let id = "cabinet"
    /// Top to bottom.
    let units: [DrawerUnit] = InteriorRaster.cabinetDrawers.map { DrawerUnit($0, contentInset: 4) }
    weak var chair: ChairElement?
    private let node = SKSpriteNode()
    private var image = StorageArt.cabinet().image
    private var looks: [DrawerLook]?
    /// A drawer slammed shut at this speed (px/s): the desk knock's trigger (M7).
    var onSlam: ((ContainerID, Float) -> Void)?

    override init(context: SceneContext) {
        super.init(context: context)
        node.isHidden = true
        root.addChild(node)
        for u in units {
            u.onOpening = { [unowned self, unowned u] in shutOthers(than: u) }
        }
    }

    override var drawnPlacements: [String] { ["cabinet"] }

    static func anchorName(_ id: ContainerID) -> String {
        "cabinet." + Anchors.cabinetDrawerNames[InteriorRaster.cabinetDrawers.firstIndex(of: id) ?? 0]
    }

    /// Interlock: one drawer open at a time.
    private func shutOthers(than u: DrawerUnit) {
        for o in units where o !== u && (o.sim.p > o.sim.closedLimit + 0.5 || o.springOpened || o.pendingOpen != nil) {
            o.close()
        }
    }

    // MARK: Geometry

    var spriteOrigin: ArtPoint { context.layout.point(StorageArt.cabinetSpriteOrigin) }
    var bodyRect: ArtRect { ArtRect(origin: spriteOrigin, size: image.size) }

    func unit(_ id: ContainerID) -> DrawerUnit? { units.first { $0.id == id } }

    func liveAnchor(_ name: String) -> ArtRect? {
        for u in units {
            let base = Self.anchorName(u.id)
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
        for u in units where u.showsMinis {
            guard let i = u.members.firstIndex(of: key) else { continue }
            let r = u.miniRects()[i].intersection(u.contentClip)
            return r.isEmpty ? nil : Self.pickable(r, key: key) { [unowned self] in hitTest($0)?.token }
        }
        return nil
    }

    /// An open drawer stops the chair rolling into the cabinet.
    var blocksChair: Bool { units.contains { $0.sim.p > $0.sim.params.chairBlockLimit + 0.5 } }

    /// The chair's left edge now (its live roll, else the model's).
    private var chairX: Float { chair?.sim.x ?? state?.chair.x ?? Float(CoreLayout.chair.x) }

    // MARK: DeskElement

    func layout(_ layout: SceneLayout) {
        for (i, u) in units.enumerated() {
            let front = CoreLayout.cabinetFront(i)
            u.closedFront = layout.rect(front)
            u.closedHandle = layout.rect(Anchors.cabinetHandle(of: front))
        }
        looks = nil
        hidePlaced()
        render()
    }

    func apply(_ s: DeskState) {
        adopt(s)
        for u in units { u.sync(s) }
        updateLimits()
        render()
    }

    func hitTest(_ p: ArtPoint) -> Hit? {
        let hidden = carried
        // The top drawer is drawn last: it answers first.
        for u in units where u.area.contains(p) {
            let name = Self.anchorName(u.id)
            if let m = u.mini(at: p, except: hidden, front: frontKeys) {
                return Hit(element: id, part: "token", rect: m.rect, token: m.key)
            }
            if u.handle.contains(p) { return Hit(element: id, part: name + ".handle", rect: u.handle) }
            if u.front.contains(p) { return Hit(element: id, part: name, rect: u.front) }
            return Hit(element: id, part: name + ".interior", rect: u.interior)
        }
        let r = bodyRect
        guard r.contains(p), image.pixel(p.x - r.x, p.y - r.y).a != 0 else { return nil }
        return Hit(element: id, part: nil, rect: context.layout.rect(CoreLayout.cabinet))
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        if let key = hit.token, let meta = state?.tokens.meta(of: key) {
            guard let u = units.first(where: { $0.members.contains(key) }), let i = u.members.firstIndex(of: key) else {
                return .none
            }
            if u.id == .cabinetFile { return Self.ring(around: hit.rect) }
            let icon = KindIcons.icon(InteriorRaster.iconKind(meta.kind), size: InteriorRaster.miniSize).image
            return Self.miniRing(icon, at: u.miniRects()[i].origin, clip: u.contentClip)
        }
        guard let part = hit.part else { return Self.outline(image, at: spriteOrigin) }
        if part.hasSuffix(".interior") { return .none }
        return units.first { part.hasPrefix(Self.anchorName($0.id)) }.map { Self.ring(around: $0.handle) } ?? .none
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        if let key = hit.token { return miniTooltip(key, anchor: hit.rect) }
        guard let s = state, let part = hit.part,
              let u = units.first(where: { part.hasPrefix(Self.anchorName($0.id)) }) else {
            return TooltipSpec(title: "Cabinet", anchor: hit.rect)
        }
        var detail = Self.countText(s.tokens.count(in: u.id), cap: u.id.spec)
        if DrawerSim.cabinetOpenLimit(travel: u.sim.travel, chairX: chairX) < u.sim.travel {
            detail += " · the chair is in the way"
        }
        return TooltipSpec(title: MenuSpec.containerTitle(u.id), detail: detail, anchor: hit.rect)
    }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard state != nil else { return .pass }
        if let key = hit.token {
            if case .scroll = gesture, let u = units.first(where: { $0.members.contains(key) }) {
                u.scroll(gesture.scrollDY)
                return .handled
            }
            return handleMini(gesture, key: key, shown: shownTokens) { [unowned self] k in
                miniRect(of: k).map(Self.carryOrigin(over:))
            }
        }
        guard let part = hit.part, let u = units.first(where: { part.hasPrefix(Self.anchorName($0.id)) }) else {
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
        guard state != nil else { return nil }
        for u in units where u.area.contains(p) {
            return u.fits(tokens) ? .accept(.container(u.id, order: u.members.count)) : .bonk(.containerFull)
        }
        return nil
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        guard let s = state else { return nil }
        if let key = hit.token { return miniMenu(key) }
        guard let part = hit.part else { return nil }
        return units.first { part.hasPrefix(Self.anchorName($0.id)) }.map { MenuSpec.container($0.id, s) }
    }

    var shownTokens: Set<TokenKey> {
        units.filter(\.showsMinis).reduce(into: Set<TokenKey>()) { $0.formUnion($1.members) }
    }

    func accessibilityItems() -> [AXItem] {
        guard let s = state else { return [] }
        var items: [AXItem] = units.map { u in
            AXItem(id: Self.anchorName(u.id), label: Self.containerLabel(u.id, count: u.members.count),
                   role: .container, frame: u.front)
        }
        for key in shownTokens.sorted() {
            guard let r = miniRect(of: key), let meta = s.tokens.meta(of: key) else { continue }
            items.append(AXItem(id: "token.\(key.inode)", label: meta.displayName, role: .token, frame: r, token: key))
        }
        return items
    }

    // MARK: Frames

    var needsFrames: Bool { units.contains { $0.needsFrames } || pulse != nil }

    /// The chair in front lowers every drawer's upper stop.
    private func updateLimits() {
        let x = chairX
        for u in units { u.setOpenLimit(DrawerSim.cabinetOpenLimit(travel: u.sim.travel, chairX: x)) }
    }

    func step(_ dt: Double) {
        updateLimits()
        let carry = carryInHand
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

    func handle(_ events: [DrawerSim.Event], of u: DrawerUnit) {
        for e in events {
            switch e {
            case let .settled(p):
                context.dispatch(.drawerSettled(u.id, p))
            case let .slam(speed):
                context.fx.puff(at: ArtPoint(u.front.midX, u.front.maxY + 1))
                context.shake(frames: 2)
                onSlam?(u.id, speed)
            case .hitChair:
                // Thunk: the front meets the chair's seat, which rolls aside.
                let x = chair.map { $0.seatRect.maxX } ?? u.front.minX
                context.fx.sparkle(at: ArtPoint(min(max(x, u.front.minX + 3), u.front.maxX - 3), u.front.maxY - 2))
                context.shake(frames: 1)
                chair?.pushedByDrawer()
            default:
                break
            }
        }
    }

    func knock(_ plan: DeskKnock.Plan) {
        for u in units {
            u.knock(closes: plan.drawerCloses.contains(u.id),
                    jostleStrength: plan.drawerJostle.contains(u.id) ? plan.strength : nil, seed: plan.seed)
        }
    }

    override func selectionChanged() { render() }

    // MARK: Drawing

    /// Redraws when something changed; true when a drawer moved.
    @discardableResult
    func render() -> Bool {
        guard state != nil else { return false }
        let hidden = carried
        let selected = drawnSelected
        let now = units.map { $0.look(hidden: hidden, selected: selected, raised: raisedKeys) }
        guard now != looks else { return false }
        let moved = looks.map { old in zip(old, now).contains { $0.p != $1.p } } ?? false
        looks = now
        image = InteriorRaster.cabinet(p: now.map(\.p), items: now.map(\.items), offsets: now.map(\.offsets),
                                       revealed: now.map(\.revealed), marks: now.map(\.marks)).image
        node.texture = TextureFactory.texture(image)
        context.space.place(node, at: ArtRect(origin: spriteOrigin, size: image.size))
        node.zPosition = context.placementZ("cabinet")
        node.isHidden = false
        return moved
    }

    /// The cabinet as drawn now (tests).
    var drawnImage: PixelBuffer { image }
}
