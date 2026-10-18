import DeskCore
import SpriteKit

/// The memo clips on the partition's right wing (메모 집게, Erratum 31): a wire with five binder clips holding up to
/// five Desktop files as cards, each the token's 12-px mini on a paper card (a polaroid for a picture), drawn here in
/// place of the room's clip rail once a model arrives. Layout only, like every hiding place, but nothing hides: the
/// cards are on show (`Concealment.shown`). Hover a card for its name, click to select, double-click to open, drag
/// one out; a drop on the wire (or on the felt, `PartitionElement`) clips files up while there is room, else bonks
/// ("The memo clips are full."). A carry in hand that would clip up rings the next free clip. The menu is the
/// container menu with Put Away Memo Clips. Nothing while they are put away.
final class MemoClipsElement: ContainerElement, DeskElement {
    let id = "partition.clips"
    private(set) var members: [TokenKey] = []
    private var items: [InteriorRaster.Item] = []
    private let node = SKSpriteNode()
    private var look: ClipsLook?

    override init(context: SceneContext) {
        super.init(context: context)
        node.isHidden = true
        root.addChild(node)
    }

    override var drawnPlacements: [String] { ["partition.clips"] }

    // MARK: Geometry

    var railRect: ArtRect { context.layout.rect(CoreLayout.partitionClips) }
    func cardRect(_ i: Int) -> ArtRect { context.layout.rect(CoreLayout.memoClipCard(i)) }
    /// Where a card shows its token's mini, inside the card.
    static let miniInset = PartitionArt.clipCardMini

    var isOut: Bool { state?.isOut(.memoClips) == true }

    /// The cards on show with their canvas rects.
    var cards: [(key: TokenKey, rect: ArtRect)] {
        guard isOut else { return [] }
        return members.prefix(ContainerID.memoClips.spec.hardCap).enumerated().map { ($1, cardRect($0)) }
    }

    func miniRect(of key: TokenKey) -> ArtRect? { cards.first { $0.key == key }?.rect }

    // MARK: DeskElement

    func layout(_ layout: SceneLayout) {
        look = nil
        hidePlaced()
        render()
    }

    func apply(_ s: DeskState) {
        adopt(s)
        members = s.tokens.members(of: .memoClips)
        items = InteriorRaster.items(.memoClips, in: s)
        render()
    }

    func hitTest(_ p: ArtPoint) -> Hit? {
        guard state != nil, isOut, railRect.contains(p) else { return nil }
        let hidden = carried
        if let c = cards.reversed().first(where: { $0.rect.contains(p) && !hidden.contains($0.key) }) {
            return Hit(element: id, part: "token", rect: c.rect, token: c.key)
        }
        return Hit(element: id, part: "partition.clips", rect: railRect)
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        Self.ring(around: hit.rect)
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        if let key = hit.token { return miniTooltip(key, anchor: hit.rect) }
        var spec = TooltipSpec(title: L10n.text(.stowMemoClips),
                               detail: Self.countText(members.count, cap: ContainerID.memoClips.spec), anchor: hit.rect)
        spec.prefersAbove = true
        return spec
    }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard state != nil else { return .pass }
        if let key = hit.token {
            return handleMini(gesture, key: key, shown: shownTokens) { [unowned self] k in
                miniRect(of: k).map(Self.carryOrigin(over:))
            }
        }
        switch gesture {
        case .press, .cancelPress: return .handled
        case .click, .dragBegan, .scroll: return .pass
        }
    }

    func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? {
        guard state != nil, isOut, railRect.contains(p) else { return nil }
        return fits(tokens) ? .accept(.container(.memoClips, order: members.count)) : .bonk(.memoClipsFull)
    }

    /// Whether `tokens` fit with the cards already clipped up (those among them only change places).
    func fits(_ tokens: [TokenKey]) -> Bool {
        let movers = Set(tokens)
        return members.filter { !movers.contains($0) }.count + movers.count <= ContainerID.memoClips.spec.hardCap
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        guard let s = state else { return nil }
        if let key = hit.token { return miniMenu(key) }
        return MenuSpec(MenuSpec.container(.memoClips, s).items + MenuSpec.memoClipsExtras(s))
    }

    var shownTokens: Set<TokenKey> { Set(cards.map(\.key)) }

    func accessibilityItems() -> [AXItem] {
        guard let s = state, isOut else { return [] }
        var out = [AXItem(id: id, label: L10n.format(.axMemoClips, [members.count]), role: .container,
                          frame: railRect)]
        for c in cards {
            guard let meta = s.tokens.meta(of: c.key) else { continue }
            out.append(AXItem(id: "token.\(c.key.inode)", label: meta.displayName, role: .token, frame: c.rect,
                              token: c.key))
        }
        return out
    }

    // MARK: Frames

    var needsFrames: Bool { pulse != nil }

    func step(_ dt: Double) {
        _ = stepPulse(dt, shown: shownTokens)
        render()
    }

    func settle() {
        endPulse(shown: shownTokens)
        render()
    }

    override func selectionChanged() { render() }

    // MARK: Drawing

    /// The next free clip rings while a carry in hand would clip up here (over the wire, or anywhere on the felt).
    private var highlight: Int? {
        guard let carry = activeCarry(), carry.phase == .carrying,
              case .accept(.container(.memoClips, _))? = carry.verdict?.verdict,
              members.count < ContainerID.memoClips.spec.hardCap
        else { return nil }
        return members.count
    }

    /// Redraws when what shows changed.
    func render() {
        guard state != nil, isOut else {
            node.isHidden = true
            look = nil
            return
        }
        let hidden = carried
        let selected = drawnSelected
        let now = ClipsLook(items: Array(items.prefix(ContainerID.memoClips.spec.hardCap)),
                            hidden: Set(members.indices.filter { hidden.contains(members[$0]) }),
                            selected: Set(members.indices.filter { selected.contains(members[$0]) }),
                            highlight: highlight)
        guard now != look else { return }
        look = now
        let image = Self.image(now)
        node.texture = TextureFactory.texture(image)
        context.space.place(node, at: ArtRect(origin: railRect.origin, size: image.size))
        node.zPosition = context.placementZ("partition.clips")
        node.isHidden = false
    }

    /// The rail with its cards (rail-local): each card under its clip, the selected ones on the selection blue, the
    /// carry's free clip ringed.
    static func image(_ look: ClipsLook) -> PixelBuffer {
        let rail = PartitionArt.clipsRail().image
        var c = PixelCanvas(width: rail.width, height: rail.height)
        let origin = CoreLayout.partitionClips.origin
        for (i, item) in look.items.enumerated() where !look.hidden.contains(i) {
            let r = CoreLayout.memoClipCard(i).offsetBy(-origin.x, -origin.y)
            let picture = item.kind == .image || item.kind == .screenshot
            c.blit(PartitionArt.clipCard(image: picture).image, at: r.origin)
            let mini = ArtRect(origin: r.origin + miniInset, size: ArtSize(InteriorRaster.miniSize, InteriorRaster.miniSize))
            if look.selected.contains(i) { c.fill(mini, Role.selection) }
            c.blit(KindIcons.icon(InteriorRaster.iconKind(item.kind), size: InteriorRaster.miniSize).image, at: mini.origin)
            if look.selected.contains(i) { c.roundedRectStroke(mini, radius: 1, InteriorRaster.selectionMark) }
        }
        if let h = look.highlight {
            let r = CoreLayout.memoClipCard(h).offsetBy(-origin.x, -origin.y)
            c.roundedRectStroke(r, radius: 1, Role.selection)
        }
        // The wire and its clips over the cards' tops: the clips hold them.
        c.blit(rail, at: .zero)
        return c.buffer
    }

    /// The clips as drawn now (tests).
    var drawnImage: PixelBuffer? { look.map(Self.image) }
}

/// What the memo clips' picture depends on.
struct ClipsLook: Equatable {
    var items: [InteriorRaster.Item]
    var hidden: Set<Int>
    var selected: Set<Int>
    var highlight: Int?
}
