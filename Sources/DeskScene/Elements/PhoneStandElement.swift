import DeskCore
import SpriteKit

/// The phone on its stand (DESIGN §2.2 E4): tokens dropped on the face-up phone become 5×5 app minis (two columns,
/// three rows; a sparkle "bloops" each arrival; past six they bonk "That's full."), a click on the phone (not on a
/// mini) flips it through three frames (`PhoneMachine`, committing `.phoneFace(down:)` at the start of the flip so
/// face-down hides at once), and face-down it hides its contents: no minis, nothing to hover or select, drops bonk.
/// Face-up its minis are selectable — hover for the name, click, double-click to open, drag one out. The menu turns
/// it face down or up. Its glow follows the model's `PhoneState` (the lighting reads it). Drawn here in place of
/// the room's phone sprite once a model arrives.
final class PhoneStandElement: ContainerElement, DeskElement {
    let id = "phone"
    private(set) var machine = PhoneMachine()
    private(set) var members: [TokenKey] = []
    private var items: [InteriorRaster.Item] = []
    private var synced = false
    private let node = SKSpriteNode()
    private var image = PropArt.phoneStand(faceUp: true).image
    private var look: PhoneLook?
    /// A knock's wobble: frames left, 1-px lean.
    private var wobble: (hop: DeskKnock.Hop, frame: Int)?

    override init(context: SceneContext) {
        super.init(context: context)
        node.isHidden = true
        root.addChild(node)
    }

    override var drawnPlacements: [String] { ["phone"] }

    // MARK: Geometry

    var phoneRect: ArtRect { context.layout.rect(CoreLayout.phone) }

    /// The minis on show (face-up at rest) with their canvas rects.
    var visibleMinis: [(key: TokenKey, rect: ArtRect)] {
        guard machine.showsContents else { return [] }
        let o = phoneRect.origin
        return members.prefix(ContainerSpec.phone.capacity).enumerated().map { i, k in
            (k, InteriorRaster.phoneMiniRect(i).offsetBy(o.x, o.y))
        }
    }

    func miniRect(of key: TokenKey) -> ArtRect? { visibleMinis.first { $0.key == key }?.rect }

    // MARK: DeskElement

    func layout(_ layout: SceneLayout) {
        look = nil
        hidePlaced()
        render()
    }

    func apply(_ s: DeskState) {
        adopt(s)
        let now = s.tokens.members(of: .phone)
        if !synced {
            synced = true
            machine = PhoneMachine(s.phone)
        } else {
            if s.phone != machine.state {
                // Turned elsewhere (the menu, Show on Desk, undo): flip there; the model already agrees.
                _ = machine.flip()
            }
            if now.contains(where: { !members.contains($0) }), !machine.state.faceDown {
                let screen = InteriorRaster.phoneMiniRect(min(now.count, ContainerSpec.phone.capacity) - 1)
                    .offsetBy(phoneRect.x, phoneRect.y)
                context.fx.sparkle(at: screen.center)
            }
        }
        members = now
        items = InteriorRaster.items(.phone, in: s)
        render()
    }

    func hitTest(_ p: ArtPoint) -> Hit? {
        let r = phoneRect
        guard r.contains(p) else { return nil }
        let hidden = carried
        if let m = visibleMinis.reversed().first(where: { $0.rect.contains(p) && !hidden.contains($0.key) }) {
            return Hit(element: id, part: "token", rect: m.rect, token: m.key)
        }
        guard image.pixel(p.x - r.x - leanDX, p.y - r.y).a != 0 else { return nil }
        return Hit(element: id, part: "phone", rect: r)
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        if let key = hit.token, let meta = state?.tokens.meta(of: key) {
            let mini = KindIcons.mini(InteriorRaster.iconKind(meta.kind)).image
            return Self.miniRing(mini, at: hit.rect.origin, clip: phoneRect)
        }
        return Self.outline(image, at: phoneRect.origin + ArtPoint(leanDX, 0))
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        if let key = hit.token { return miniTooltip(key, anchor: hit.rect) }
        guard state != nil else { return TooltipSpec(title: "Phone", anchor: hit.rect) }
        let detail = machine.state.faceDown ? "Face down" : Self.countText(members.count, cap: .phone)
        return TooltipSpec(title: "Phone", detail: detail, anchor: hit.rect)
    }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard state != nil else { return .pass }
        if let key = hit.token {
            return handleMini(gesture, key: key, shown: shownTokens) { [unowned self] k in
                miniRect(of: k).map(Self.carryOrigin(over:))
            }
        }
        switch gesture {
        case .press, .cancelPress:
            return .handled
        case let .click(_, _, count):
            if count == 1 { flip() }
            return .handled
        case .dragBegan, .scroll:
            return .pass
        }
    }

    /// Click: flip, committing the new face to the model at once.
    func flip() {
        for case let .committed(faceDown) in machine.flip() {
            if let s = state, let a = PhoneMachine.action(committing: faceDown, model: s.phone) { context.dispatch(a) }
        }
        render()
    }

    func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? {
        guard state != nil, phoneRect.contains(p) else { return nil }
        guard machine.phase == .faceUp else { return .bonk(nil) }
        let movers = Set(tokens)
        let staying = members.filter { !movers.contains($0) }.count
        return staying + movers.count <= ContainerSpec.phone.hardCap
            ? .accept(.container(.phone, order: members.count)) : .bonk(.containerFull)
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        guard let s = state else { return nil }
        if let key = hit.token { return miniMenu(key) }
        return MenuSpec.container(.phone, s)
    }

    var shownTokens: Set<TokenKey> { Set(visibleMinis.map(\.key)) }

    func accessibilityItems() -> [AXItem] {
        guard let s = state else { return [] }
        let label = machine.state.faceDown ? "Phone, face down" : Self.containerLabel(.phone, count: members.count)
        var items = [AXItem(id: "phone", label: label, role: .container, frame: phoneRect)]
        for m in visibleMinis {
            guard let meta = s.tokens.meta(of: m.key) else { continue }
            items.append(AXItem(id: "token.\(m.key.inode)", label: meta.displayName, role: .token, frame: m.rect,
                                token: m.key))
        }
        return items
    }

    // MARK: Frames

    var needsFrames: Bool { machine.needsFrames || wobble != nil || pulse != nil }

    func step(_ dt: Double) {
        _ = machine.step(Float(dt))
        if let w = wobble { wobble = w.frame + 1 >= w.hop.endFrame ? nil : (w.hop, w.frame + 1) }
        _ = stepPulse(dt, shown: shownTokens)
        if render() { refreshHover() }
    }

    func settle() {
        for _ in 0..<12 where machine.needsFrames { _ = machine.step(1.0 / 30) }
        wobble = nil
        endPulse(shown: shownTokens)
        render()
    }

    /// A desk knock's wobble (M7 calls this with `DeskKnock.Plan.wobbles[.phone]`).
    func knock(_ hop: DeskKnock.Hop) {
        wobble = (hop, 0)
    }

    private var leanDX: Int { wobble.map { $0.hop.lean(atFrame: $0.frame) } ?? 0 }

    override func selectionChanged() { render() }

    // MARK: Drawing

    /// Redraws when something changed; true when the phone turned or wobbled.
    @discardableResult
    func render() -> Bool {
        guard state != nil else { return false }
        let hidden = carried
        let selected = drawnSelected
        let shows = machine.showsContents
        let now = PhoneLook(face: machine.face, items: shows ? Array(items.prefix(ContainerSpec.phone.capacity)) : [],
                            hidden: Set(members.indices.filter { hidden.contains(members[$0]) }),
                            selected: shows ? Set(members.indices.filter { selected.contains(members[$0]) }) : [],
                            dx: leanDX)
        guard now != look else { return false }
        let moved = look.map { $0.face != now.face || $0.dx != now.dx } ?? false
        look = now
        let blank = PixelBuffer(width: 5, height: 5)
        let minis = InteriorRaster.phoneMinis(now.items).enumerated().map {
            now.hidden.contains($0.offset) ? blank : $0.element
        }
        var c = PixelCanvas(PropArt.phoneStand(face: now.face, minis: minis).image)
        for i in now.selected where i < minis.count {
            c.stroke(InteriorRaster.phoneSelectionRect(i), InteriorRaster.selectionMark)
        }
        image = c.buffer
        node.texture = TextureFactory.texture(image)
        context.space.place(node, at: ArtRect(origin: phoneRect.origin + ArtPoint(now.dx, 0), size: image.size))
        node.zPosition = context.placementZ("phone")
        node.isHidden = false
        return moved
    }

    /// The phone as drawn now (tests).
    var drawnImage: PixelBuffer { image }
}

/// What the phone's picture depends on.
struct PhoneLook: Equatable {
    var face: PropArt.PhoneFace
    var items: [InteriorRaster.Item]
    var hidden: Set<Int>
    var selected: Set<Int>
    var dx: Int
}
