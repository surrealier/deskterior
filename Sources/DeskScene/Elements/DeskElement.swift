import DeskCore
import SpriteKit

/// What a pointer is over: an element, and the most specific named anchor of it under the point.
public struct Hit: Hashable, Sendable {
    public let element: String
    /// An anchor name ("monitor.power", "riser.drawerL.handle", …), or nil for the element's body.
    public let part: String?
    /// Canvas rect to highlight: the part's anchor rect, or the element's bounds.
    public let rect: ArtRect

    public init(element: String, part: String?, rect: ArtRect) {
        self.element = element
        self.part = part
        self.rect = rect
    }
}

/// One interactive or decorative thing in the room (DESIGN §4.4). Elements own SpriteKit nodes under `root`,
/// place them through `ArtSpace`, and answer pixel-precise hit tests in canvas art px.
public protocol DeskElement: AnyObject {
    var id: String { get }
    var root: SKNode { get }
    /// Adopts a solved layout (canvas size, core placement, anchors).
    func layout(_ layout: SceneLayout)
    /// The hit under canvas pixel `p`, if any.
    func hitTest(_ p: ArtPoint) -> Hit?
    /// True while the element animates on its own.
    var needsFrames: Bool { get }
    func step(_ dt: Double)
}

/// The shared element for the M3 room: it shows the `RoomPlan` placements it owns (one sprite node each, z from
/// the placement's layer) and hit-tests them by alpha, then by the element's anchors.
public final class PlacedElement: DeskElement {
    public let id: String
    public let root = SKNode()
    /// Anchor names this element answers for: each prefix itself and every `prefix.…` below it.
    public let anchorPrefixes: [String]

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

    public var needsFrames: Bool { false }

    public func step(_ dt: Double) {}
}
