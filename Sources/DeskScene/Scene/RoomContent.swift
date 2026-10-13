import DeskCore
import SpriteKit

/// The room (DESIGN §1.3, M3): the `RoomPlan` placements shown through one `PlacedElement` per object, z-ordered
/// by layer, plus the light mask and ambient level for the lit pass. Hovering an element draws a 1-px ring
/// around it (or around the control under the pointer); there are no other interactions yet.
final class RoomContent {
    let root = SKNode()
    private(set) var layout: SceneLayout
    private(set) var state: RoomState
    private(set) var elements: [PlacedElement] = []
    private(set) var hovered: Hit?
    private(set) var lightMask: LightMask
    private(set) var ambient: AmbientLight

    private var space: ArtSpace
    private var byID: [String: PlacedElement] = [:]
    /// Stable draw order of every placement id (from the last full build).
    private var order: [String: Int] = [:]
    private let hoverNode = SKSpriteNode()

    static let hoverInk = Role.selection

    init(grid: PixelGrid, state: RoomState, avoid: [ArtRect] = []) {
        layout = LayoutSolver.solve(grid: grid, avoid: avoid)
        self.state = state
        space = ArtSpace(canvas: grid.artSize)
        lightMask = LightMask(size: grid.artSize)
        ambient = .identity
        hoverNode.zPosition = CGFloat(RoomLayer.ui.rawValue * 1000)
        hoverNode.isHidden = true
        root.addChild(hoverNode)
        rebuild()
    }

    // MARK: Building

    /// Rebuilds everything for the current layout and state.
    private func rebuild() {
        let all = RoomPlan.placements(layout, state)
        order = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element.id, $0.offset) })
        for e in elements { e.root.removeFromParent() }
        elements = []
        byID = [:]
        var groups: [String: [RoomPlacement]] = [:]
        var groupOrder: [String] = []
        for p in all {
            let eid = Self.elementID(for: p.id)
            if groups[eid] == nil { groupOrder.append(eid) }
            groups[eid, default: []].append(p)
        }
        for eid in groupOrder {
            let e = PlacedElement(id: eid, anchorPrefixes: Self.anchorPrefixes(for: eid))
            e.layout(layout)
            e.apply(groups[eid]!, replacingAll: true, z: zPosition)
            root.addChild(e.root)
            elements.append(e)
            byID[eid] = e
        }
        updateLighting()
        setHovered(nil)
    }

    /// Refreshes only the placements in `ids` (state changes); `relight` also rebuilds the light mask.
    private func refresh(_ ids: Set<String>, relight: Bool) {
        let fresh = RoomPlan.placements(layout, state, only: ids)
        var groups: [String: [RoomPlacement]] = [:]
        for p in fresh { groups[Self.elementID(for: p.id), default: []].append(p) }
        for (eid, ps) in groups {
            guard let e = byID[eid] else { return rebuild() }
            e.apply(ps, replacingAll: false, z: zPosition)
        }
        if relight { updateLighting() }
    }

    private func zPosition(_ p: RoomPlacement) -> CGFloat {
        CGFloat(p.layer.rawValue * 1000 + (order[p.id] ?? 999))
    }

    private func updateLighting() {
        let tod = state.timeOfDay
        lightMask = LightMask.room(layout, lights: state.effectiveLights, time: tod)
        ambient = AmbientLight(level: tod.ambientLevel, tint: tod.ambientTint)
    }

    /// The element that owns a placement id.
    static func elementID(for placementID: String) -> String {
        switch placementID {
        case "backdrop": "room"
        case "desk.front": "desk"
        case "room.switch": "room.switch"
        default:
            if placementID.hasPrefix("decor.") { placementID }
            else if let dot = placementID.firstIndex(of: ".") { String(placementID[..<dot]) }
            else { placementID }
        }
    }

    static func anchorPrefixes(for elementID: String) -> [String] {
        switch elementID {
        case "room": ["desk.top", "mat", "floor"]
        case "desk": ["apron"]
        default: [elementID]
        }
    }

    // MARK: Updates

    /// Adopts a new grid (and avoid rects): full rebuild.
    func relayout(grid: PixelGrid, avoid: [ArtRect]) {
        layout = LayoutSolver.solve(grid: grid, avoid: avoid)
        space = ArtSpace(canvas: grid.artSize)
        rebuild()
    }

    /// Adopts a new state, rebuilding only what it changes. True when anything visible changed.
    @discardableResult
    func setState(_ new: RoomState) -> Bool {
        guard new != state else { return false }
        let old = state
        state = new
        let a = old.timeOfDay, b = new.timeOfDay
        let sameLight = a.sky == b.sky && a.ambientLevel == b.ambientLevel && a.ambientTint == b.ambientTint
            && old.effectiveLights == new.effectiveLights && old.lightsMode == new.lightsMode
        let sameRest = old.riserOpen == new.riserOpen && old.cabinetOpen == new.cabinetOpen
            && old.chairX == new.chairX && old.chairFacing == new.chairFacing
        let minuteOnly = sameLight && sameRest
        refresh(minuteOnly ? RoomPlan.minuteIDs : RoomPlan.stateDependentIDs, relight: !minuteOnly)
        return true
    }

    // MARK: Input

    /// Front-to-back hit test in canvas px (the room backdrop answers last).
    func hitTest(_ p: ArtPoint) -> Hit? {
        let ordered = elements.sorted { maxZ($0) > maxZ($1) }
        for e in ordered where e.id != "room" {
            if let hit = e.hitTest(p) { return hit }
        }
        return byID["room"]?.hitTest(p)
    }

    private func maxZ(_ e: PlacedElement) -> CGFloat {
        e.placements.map(zPosition).max() ?? 0
    }

    /// True when something visible changed.
    func handle(_ event: InputEvent) -> Bool {
        switch event.kind {
        case .move, .drag:
            let hit = hitTest(event.artPixel)
            return setHovered(hit?.element == "room" ? nil : hit)
        case .down, .up, .rightDown, .scroll, .key:
            return false
        }
    }

    @discardableResult
    private func setHovered(_ hit: Hit?) -> Bool {
        guard hit != hovered else { return false }
        hovered = hit
        guard let hit, let e = byID[hit.element] else {
            hoverNode.isHidden = true
            return true
        }
        let ring: PixelBuffer
        let origin: ArtPoint
        if hit.part != nil {
            var c = PixelCanvas(width: hit.rect.w + 2, height: hit.rect.h + 2)
            c.roundedRectStroke(c.bounds, radius: 1, Self.hoverInk)
            ring = c.buffer
            origin = ArtPoint(hit.rect.x - 1, hit.rect.y - 1)
        } else {
            let b = e.bounds
            ring = e.silhouette().outlined(Self.hoverInk)
            origin = ArtPoint(b.x - 1, b.y - 1)
        }
        hoverNode.texture = TextureFactory.texture(ring)
        space.place(hoverNode, at: ArtRect(origin: origin, size: ring.size))
        hoverNode.isHidden = false
        return true
    }
}
