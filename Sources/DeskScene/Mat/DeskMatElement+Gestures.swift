import DeskCore
import SpriteKit

/// What the mat answers to (DESIGN §2.1, §2.2 E9): hits from the raster's `owner[]` (the cloth, or a pile under it the
/// cloth has lifted off), the bare desk in front of the back strip (the scroll-broom's ground), grabs, double-clicks,
/// the ⌥ transform handles, the context menu and its commands.
extension DeskMatElement {
    // MARK: Hits

    /// The bare desk top below the back strip (core y 176…232): nothing else stands there, so the mat answers there
    /// for the scroll-broom (clicks, drags and menus pass through to the room's own handling).
    var deskBand: ArtRect {
        let top = CoreLayout.deskFrontY - Int(DeskPlanePhysics.backStripD * DeskProjection.standard.k) + 2
        return context.layout.rect(ArtRect(CoreLayout.deskTop.x, top, CoreLayout.deskTop.w, CoreLayout.deskFrontY - top))
    }

    func hitTest(_ p: ArtPoint) -> Hit? {
        guard isLive else { return nil }
        lastHitPoint = SIMD2(Float(p.x) + 0.5, Float(p.y) + 0.5)
        if rasterDirty { render() }
        let o = owner(at: p)
        if o >= 0 { return clothHit(particle: Int(o), at: p) }
        if let n = DeskSurfaceRaster.pileID(owner: o), let id = pile(number: n), let b = billboards[id] {
            return Hit(element: self.id, part: "pile.\(id.raw)",
                       rect: ArtRect(origin: b.stackOrigin, size: b.stack.image.size), token: b.keys.first)
        }
        let band = deskBand
        return band.contains(p) ? Hit(element: id, part: "desk", rect: band) : nil
    }

    /// The cloth under the pointer: a folded flap, a corner or an edge (their affordance rides the pointer), or the
    /// body.
    private func clothHit(particle i: Int, at p: ArtPoint) -> Hit {
        let near = ArtRect(p.x - 3, p.y - 5, 7, 7)
        if cloth.isFolded(i), !isFlat { return Hit(element: id, part: "mat.flap", rect: near) }
        switch cloth.region(of: i) {
        case .corner: return Hit(element: id, part: "mat.corner", rect: near)
        case .edge: return Hit(element: id, part: "mat.edge", rect: near)
        case .interior: return Hit(element: id, part: "mat", rect: bounds)
        }
    }

    func pileID(_ hit: Hit) -> PileID? {
        guard let part = hit.part, part.hasPrefix("pile.") else { return nil }
        return PileID(String(part.dropFirst(5)))
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        if let id = pileID(hit), let b = billboards[id] {
            return .image(TokenArt.hoverRing(b.stack.hitMask), at: ArtPoint(b.stackOrigin.x - 2, b.stackOrigin.y - 2))
        }
        switch hit.part {
        case "mat.edge", "mat.corner", "mat.flap":
            // The edge curls up a little under the pointer: lift here.
            return .image(Self.curl, at: ArtPoint(hit.rect.x, hit.rect.y))
        default:
            return .none
        }
    }

    /// The edge-curl affordance (DESIGN §2.1 hover): a dog-eared corner showing the mat's rubber underside.
    static let curl: PixelBuffer = IndexedSprite("""
        .....kk
        ....kuk
        ...kuuk
        ..kuuik
        .kuuiik
        kkkkkkk
        """, SpriteKey.extending(["k": Role.outline, "u": MatPattern.felt.undersideRamp[4],
                                 "i": MatPattern.felt.undersideRamp[2]]))
        .render()

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        if let id = pileID(hit), let b = billboards[id], let s = context.state {
            let metas = b.keys.compactMap { s.tokens.meta(of: $0) }
            guard let top = metas.first else { return nil }
            var spec: TooltipSpec
            if metas.count == 1 {
                spec = TooltipSpec(title: top.displayName, detail: TokenArt.detail(top), anchor: hit.rect)
            } else {
                let names = metas.prefix(3).map(\.displayName).joined(separator: ", ")
                spec = TooltipSpec(title: "\(metas.count) items", detail: metas.count > 3 ? names + "…" : names,
                                   anchor: hit.rect)
            }
            spec.prefersAbove = true
            return spec
        }
        guard hit.part != "desk" else { return nil }
        let n = coveredTokens.count
        var spec = TooltipSpec(title: "Desk Mat", detail: n == 0 ? nil : "\(n) item\(n == 1 ? "" : "s") under it",
                               anchor: hit.rect)
        spec.prefersAbove = true
        return spec
    }

    // MARK: Gestures

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard isLive else { return .pass }
        if let id = pileID(hit) { return handlePile(gesture, id) }
        if case let .scroll(p, delta, _) = gesture {
            // The scroll-broom: a horizontal two-finger scroll over the desk sweeps with an invisible brush.
            guard abs(delta.x) > abs(delta.y), let brush else { return .pass }
            brush.broom(at: p, dx: delta.x)
            return .handled
        }
        guard hit.part != "desk" else { return .pass }
        switch gesture {
        case let .press(_, mods):
            showsHandles = mods.contains(.option)
            return .handled
        case let .click(_, _, count):
            showsHandles = false
            guard count == 2 else { return .pass }
            if hit.part == "mat.flap" {
                cloth.unfold()
            } else if hit.part == "mat.edge" || hit.part == "mat.corner" {
                cloth.smooth()
            } else {
                return .pass
            }
            rasterDirty = true
            return .handled
        case let .dragBegan(from, at, mods):
            guard let i = particle(at: from) else { return .pass }
            showsHandles = mods.contains(.option)
            cloth.beginGrab(particle: i, cursor: core(from), modifiers: Self.clothMods(mods))
            cloth.moveGrab(to: core(at), modifiers: Self.clothMods(mods))
            let grab = MatGrab(mat: self)
            grabbing = grab
            return .drag(grab)
        case .cancelPress:
            showsHandles = false
            return .handled
        case .scroll:
            return .pass
        }
    }

    /// The particle drawn at canvas point `p`, else the one nearest it on screen (within a few px).
    func particle(at p: SIMD2<Float>) -> Int? {
        let o = owner(at: Self.pixel(p - 0.5))
        if o >= 0 { return Int(o) }
        var best: (i: Int, d: Float)?
        for i in 0..<cloth.count {
            let d = simd_length(canvas(particle: i) - p)
            if best == nil || d < best!.d { best = (i, d) }
        }
        return best.flatMap { $0.d <= 6 ? $0.i : nil }
    }

    static func clothMods(_ mods: InputEvent.Modifiers) -> ClothGrabModifiers {
        var m: ClothGrabModifiers = []
        if mods.contains(.option) { m.insert(.option) }
        if mods.contains(.shift) { m.insert(.shift) }
        return m
    }

    /// A pile the cloth was lifted off: picked like a desk pile (select, open, carry).
    private func handlePile(_ gesture: Gesture, _ id: PileID) -> GestureResponse {
        guard let b = billboards[id] else { return .pass }
        let selection = context.selection
        let keys = Set(b.keys)
        switch gesture {
        case let .press(_, mods):
            if mods.contains(.command), keys.isSubset(of: selection.keys) {
                selection.set(selection.keys.subtracting(keys))
            } else if mods.contains(.command) || mods.contains(.shift) {
                selection.set(selection.keys.union(keys), primary: b.keys.first)
            } else if !keys.isSubset(of: selection.keys) {
                selection.set(keys, primary: b.keys.first)
            }
            context.screen?.refreshIfSelectionChanged()
            return .handled
        case let .click(_, mods, count):
            if count == 2 {
                context.dispatch(.requestOpen(b.keys))
            } else if count == 1, mods.isEmpty {
                selection.set(keys, primary: b.keys.first)
                context.screen?.refreshIfSelectionChanged()
            }
            return .handled
        case let .dragBegan(from, at, _):
            let origins = b.keys.indices.map { i -> ArtPoint in
                let o = b.stack.iconOrigins[min(i, b.stack.iconOrigins.count - 1)]
                return ArtPoint(b.stackOrigin.x + o.x, b.stackOrigin.y + o.y)
            }
            hub?.bodies.thaw(near: b.position)
            let session = CarrySession(keys: b.keys, origins: origins, grab: from, context: context)
            session.moved(to: at, mods: [])
            hub?.syncBodies()
            rasterDirty = true
            return .drag(session)
        case .scroll, .cancelPress:
            return .pass
        }
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        guard isLive, let s = context.state else { return nil }
        if let id = pileID(hit), let b = billboards[id] {
            let selection = context.selection
            if !Set(b.keys).isSubset(of: selection.keys) { selection.set(Set(b.keys), primary: b.keys.first) }
            context.screen?.refreshIfSelectionChanged()
            return MenuSpec.token(selection.sorted, s)
        }
        guard hit.part != "desk" else { return nil }
        return MenuSpec.mat(s, menuInfo())
    }

    /// What the menu can do with the cloth as it lies.
    func menuInfo() -> MenuSpec.MatInfo {
        var info = MenuSpec.MatInfo()
        let angle = cloth.matFrame().angle, size = cloth.restSize
        let step: Float = 15 * .pi / 180
        info.folded = !isFlat && ClothMetrics.foldedCount(cloth) > 0
        info.canRotateCW = cloth.canTransform(size: size, angle: angle - step)
        info.canRotateCCW = cloth.canTransform(size: size, angle: angle + step)
        info.canStraighten = cloth.canTransform(size: size, angle: 0)
        info.sizes = Set(MatSize.allCases.filter { cloth.canTransform(size: $0.dimensions, angle: angle) })
        info.size = MatSize.matching(size)
        info.flat = isFlat
        info.under = coveredTokens
        return info
    }

    var shownTokens: Set<TokenKey> { Set(billboards.values.flatMap(\.keys)) }

    func accessibilityItems() -> [AXItem] {
        guard isLive, let s = context.state else { return [] }
        let n = coveredTokens.count
        var items = [AXItem(id: "mat", label: n == 0 ? "Desk Mat" : "Desk Mat, \(n) item\(n == 1 ? "" : "s") under it",
                            role: .container, frame: bounds)]
        for (id, b) in billboards.sorted(by: { $0.key < $1.key }) {
            let names = b.keys.compactMap { s.tokens.meta(of: $0)?.displayName }
            items.append(AXItem(id: "pile.\(id.raw)", label: "Under the mat: " + names.joined(separator: ", "),
                                role: .group, frame: ArtRect(origin: b.stackOrigin, size: b.stack.image.size),
                                token: b.keys.first))
        }
        return items
    }

    // MARK: Commands

    /// A mat command from its menu or the status item.
    func perform(_ command: MatCommand) {
        guard isLive else { return }
        if cloth.grabMode != nil { cloth.endGrab() }
        let angle = cloth.matFrame().angle
        switch command {
        case .smooth: cloth.smooth()
        case .unfold: cloth.unfold()
        case let .rotate(degrees): cloth.transform(size: cloth.restSize, angle: angle + degrees * .pi / 180)
        case .straighten: cloth.transform(size: cloth.restSize, angle: 0)
        case let .size(size): cloth.transform(size: size.dimensions, angle: angle)
        case .peekUnder: peek(at: peekTarget(near: lastHitPoint.map { plane(canvas: $0) } ?? cloth.centroid))
        case .reset: reset()
        }
        rasterDirty = true
    }

    /// What Peek Under lifts the cloth off: the covered pile nearest desk point `p` (within 40 px), else `p`.
    func peekTarget(near p: SIMD2<Float>) -> SIMD2<Float> {
        guard let s = context.state else { return p }
        let near = coveredPiles.compactMap { s.piles[$0] }.min { simd_length($0 - p) < simd_length($1 - p) }
        return near.flatMap { simd_length($0 - p) <= 40 ? $0 : nil } ?? p
    }

    /// Peek Under: the edge nearest desk point `p` lifts for 1.5 s (not in `matMode=flat`).
    func peek(at p: SIMD2<Float>) {
        guard !isFlat else { return }
        cloth.peekUnder(p)
        rasterDirty = true
    }

    /// Reset Mat: a fresh, flat mat at the default place, size and angle, the keyboard back on it.
    func reset() {
        var fresh = ClothSim(params: params)
        fresh.setKeyboard(MatState().keyboardFootprint)
        cloth = fresh
        resetJudgements()
    }

    /// The desk-plane point under canvas point `p` (on the desk top).
    func plane(canvas p: SIMD2<Float>) -> SIMD2<Float> {
        let q = DeskProjection.standard.unproject(core(p), z: 0)
        return SIMD2(q.x, q.y)
    }

    // MARK: Handles

    /// The ⌥ transform handles: a square at each corner of the mat (drag one to size and turn the mat; drag inside
    /// to slide it without wrinkles).
    func drawHandles() {
        guard showsHandles, isLive else {
            handles.isHidden = true
            return
        }
        let corners = cloth.cornerIndices.map { canvas(particle: $0) }
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for c in corners {
            lo = pointwiseMin(lo, c)
            hi = pointwiseMax(hi, c)
        }
        guard lo.isFinite, hi.isFinite else { return }
        let origin = ArtPoint(Int(lo.x.rounded()) - 3, Int(lo.y.rounded()) - 3)
        var c = PixelCanvas(width: Int((hi.x - lo.x).rounded()) + 8, height: Int((hi.y - lo.y).rounded()) + 8)
        for p in corners {
            let x = Int(p.x.rounded()) - origin.x - 2, y = Int(p.y.rounded()) - origin.y - 2
            c.fill(ArtRect(x, y, 5, 5), Role.selection)
            c.fill(ArtRect(x + 1, y + 1, 3, 3), .neutral9)
        }
        handles.texture = TextureFactory.texture(c.buffer)
        context.space.place(handles, at: ArtRect(origin: origin, size: c.buffer.size))
        handles.isHidden = false
    }
}

/// A mat grab in hand (DESIGN §2.2 E9 grab modes): the pointer drives the cloth's grab, which `ClothSim` turns into a
/// carry, a ⌥ slide, a peel, a tug, a ⌥ transform or an unpeel; letting go ends it (a carry keeps some of its speed,
/// a peel lays back or stays folded). Esc lets go where it is: a mat cannot spring back.
final class MatGrab: DragController {
    unowned let mat: DeskMatElement
    private(set) var isFinished = false

    init(mat: DeskMatElement) {
        self.mat = mat
    }

    var needsFrames: Bool { !isFinished }

    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard !isFinished else { return }
        mat.cloth.moveGrab(to: mat.core(p), modifiers: DeskMatElement.clothMods(mods))
        mat.hub?.bodies.thaw(near: mat.plane(canvas: p))
    }

    func ended(at p: SIMD2<Float>, velocity: SIMD2<Float>, mods: InputEvent.Modifiers) {
        guard !isFinished else { return }
        moved(to: p, mods: mods)
        finish()
    }

    func cancelled() {
        finish()
    }

    private func finish() {
        isFinished = true
        mat.cloth.endGrab()
        mat.showsHandles = false
        mat.rasterDirty = true
    }

    func step(_ dt: Double) {}
}
