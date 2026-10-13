import DeskCore
import SpriteKit

/// What a pointer is over: an element, and the most specific named anchor of it under the point.
public nonisolated struct Hit: Hashable, Sendable {
    public let element: String
    /// An anchor name ("monitor.power", "riser.drawerL.handle", …), "token" for a token, or nil for the element's
    /// body.
    public let part: String?
    /// Canvas rect to highlight: the part's anchor rect, the token's icon, or the element's bounds.
    public let rect: ArtRect
    /// The token under the pointer (token hits only).
    public let token: TokenKey?

    public init(element: String, part: String?, rect: ArtRect, token: TokenKey? = nil) {
        self.element = element
        self.part = part
        self.rect = rect
        self.token = token
    }
}

/// One interactive or decorative thing in the room (DESIGN §4.2, §4.4). Elements own SpriteKit nodes under `root`,
/// place them through `ArtSpace`, answer pixel-precise hit tests in canvas art px, and react to gestures the
/// `InputRouter` recognizes. Everything but identity, nodes, layout and hit-testing has a default, so a
/// decorative element is a few lines and an interactive one implements only what it does:
///
/// - `apply` adopts committed model state (`SceneSync` pushes every change);
/// - `hover`/`hoverStyle`/`tooltip` shape the 1-px ring and the delayed Galmuri9 tooltip;
/// - `handle` answers a gesture: `.handled`, `.drag(controller)` to follow a drag, or `.pass` for the router's
///   bare-desk fallback (clear the selection, the wall menu);
/// - `dropVerdict` says where carried tokens released over the element go (`DropResolver` asks front to back);
/// - `menu` builds the right-click `MenuSpec` (nil falls back to the desk menu);
/// - `shownTokens` lists the tokens it draws and lets the user pick: the selection keeps only tokens some element
///   shows, so keys and menus never act on a hidden token (an element that shows minis must list them);
/// - `step`/`needsFrames`/`settle` run bounded animations under the frame loop (hard sleep calls `settle`);
/// - `accessibilityItems` lists what VoiceOver should offer.
///
/// Elements change the model only by dispatching `DeskAction`s through their `SceneContext`; continuous motion
/// stays in the scene until it settles. An interactive element joins the room with
/// `RoomContent.install(_:inSlotOf:)`, taking over a placed object's place in the hit-test order (the screen and
/// monitor take the monitor's).
public protocol DeskElement: AnyObject {
    var id: String { get }
    var root: SKNode { get }
    /// Adopts a solved layout (canvas size, core placement, anchors).
    func layout(_ layout: SceneLayout)
    /// Adopts committed model state.
    func apply(_ state: DeskState)
    /// The hit under canvas pixel `p`, if any.
    func hitTest(_ p: ArtPoint) -> Hit?
    /// The pointer moved onto one of this element's hits (nil: it left). True when something visible changed.
    func hover(_ hit: Hit?) -> Bool
    func hoverStyle(_ hit: Hit) -> HoverStyle
    func tooltip(_ hit: Hit) -> TooltipSpec?
    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse
    /// Where `tokens` released at `p` would go, or nil when the element does not take drops there.
    func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict?
    func menu(_ hit: Hit) -> MenuSpec?
    /// Tokens drawn now that the user can select (carried ones included).
    var shownTokens: Set<TokenKey> { get }
    func accessibilityItems() -> [AXItem]
    /// True while the element animates on its own.
    var needsFrames: Bool { get }
    func step(_ dt: Double)
    /// Hard sleep: jump every animation to its final frame.
    func settle()
}

extension DeskElement {
    public func apply(_ state: DeskState) {}
    public func hover(_ hit: Hit?) -> Bool { false }
    public func hoverStyle(_ hit: Hit) -> HoverStyle { .standard }
    public func tooltip(_ hit: Hit) -> TooltipSpec? { nil }
    public func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse { .pass }
    public func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? { nil }
    public func menu(_ hit: Hit) -> MenuSpec? { nil }
    public var shownTokens: Set<TokenKey> { [] }
    public func accessibilityItems() -> [AXItem] { [] }
    public var needsFrames: Bool { false }
    public func step(_ dt: Double) {}
    public func settle() {}
}

/// The shared element for the M3 room: it shows the `RoomPlan` placements it owns (one sprite node each, z from
/// the placement's layer) and hit-tests them by alpha, then by the element's anchors. Until an object gets its
/// own element (waves 4b/5), this is all it does, plus a tooltip title and an optional fixed drop policy.
public final class PlacedElement: DeskElement {
    public let id: String
    public let root = SKNode()
    /// Anchor names this element answers for: each prefix itself and every `prefix.…` below it.
    public let anchorPrefixes: [String]
    /// The hover tooltip ("Desk Lamp"), if any.
    public var title: String?
    /// What tokens dropped on the element's pixels get (the drive hub bonks, E15).
    public var dropPolicy: DropVerdict?

    private(set) var layoutValue: SceneLayout?
    private var space = ArtSpace(canvas: .zero)
    private(set) var placements: [RoomPlacement] = []
    private var nodes: [String: SKSpriteNode] = [:]
    private var shown: [String: (name: String, image: PixelBuffer)] = [:]

    public init(id: String, anchorPrefixes: [String]? = nil) {
        self.id = id
        self.anchorPrefixes = anchorPrefixes ?? [id]
    }

    public func layout(_ layout: SceneLayout) {
        if layoutValue?.canvas != layout.canvas { space = ArtSpace(canvas: layout.canvas) }
        layoutValue = layout
        shown.removeAll()
    }

    /// Shows `new` (placements owned by this element); `z` gives each one's zPosition. With `replacingAll`,
    /// placements missing from `new` are removed; otherwise they stay as they are.
    func apply(_ new: [RoomPlacement], replacingAll: Bool, z: (RoomPlacement) -> CGFloat) {
        var keep = Set<String>()
        for p in new {
            keep.insert(p.id)
            let node: SKSpriteNode
            if let n = nodes[p.id] {
                node = n
            } else {
                node = SKSpriteNode()
                node.name = p.id
                nodes[p.id] = node
                root.addChild(node)
            }
            let image = p.image
            if let old = shown[p.id], old.name == p.sprite.name, old.image == image {
                // Same pixels: keep the texture.
            } else {
                node.texture = TextureFactory.texture(image)
                shown[p.id] = (p.sprite.name, image)
            }
            space.place(node, at: p.rect)
            node.zPosition = z(p)
        }
        for (pid, node) in nodes where replacingAll && !keep.contains(pid) {
            node.removeFromParent()
            nodes[pid] = nil
            shown[pid] = nil
        }
        // Merge: keep placements for ids not in this update.
        var merged = replacingAll ? [] : placements.filter { !keep.contains($0.id) }
        merged.append(contentsOf: new)
        placements = merged
    }

    /// Placements in front-to-back order.
    private var frontToBack: [RoomPlacement] {
        placements.sorted { a, b in
            let za = nodes[a.id]?.zPosition ?? 0, zb = nodes[b.id]?.zPosition ?? 0
            return za > zb
        }
    }

    public func hitTest(_ p: ArtPoint) -> Hit? {
        guard let layout = layoutValue else { return nil }
        let anchors = layout.anchors
        let mine = anchors.names.filter { name in
            anchorPrefixes.contains { name == $0 || name.hasPrefix($0 + ".") }
        }
        let opaque = frontToBack.contains { pl in
            pl.rect.contains(p) && pl.sprite.hits(ArtPoint(p.x - pl.origin.x, p.y - pl.origin.y), frame: pl.frame)
        }
        let interactive = Set(Anchors.interactive)
        let parts = mine.filter { name in
            guard let r = anchors[name], r.contains(p), name != id else { return false }
            return opaque || interactive.contains(name)
        }
        guard opaque || !parts.isEmpty else { return nil }
        let part = parts.min { anchors[$0]!.size.area < anchors[$1]!.size.area }
        let rect = part.flatMap { anchors[$0] } ?? bounds
        return Hit(element: id, part: part, rect: rect)
    }

    /// The union of every placement's rect.
    public var bounds: ArtRect {
        placements.reduce(ArtRect.zero) { $0.union($1.rect) }
    }

    /// The element's silhouette in canvas px (for hover outlines), cropped to `bounds`.
    func silhouette() -> PixelBuffer {
        let b = bounds
        var out = PixelBuffer(width: max(1, b.w), height: max(1, b.h))
        for pl in placements.sorted(by: { (nodes[$0.id]?.zPosition ?? 0) < (nodes[$1.id]?.zPosition ?? 0) }) {
            out.blit(pl.image, at: ArtPoint(pl.origin.x - b.x, pl.origin.y - b.y))
        }
        return out
    }

    public func tooltip(_ hit: Hit) -> TooltipSpec? {
        title.map { TooltipSpec(title: $0, anchor: hit.rect) }
    }

    public func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? {
        guard let dropPolicy, hitTest(p) != nil else { return nil }
        return dropPolicy
    }
}
