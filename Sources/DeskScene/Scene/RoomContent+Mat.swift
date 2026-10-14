import DeskCore
import SpriteKit

/// The desk mat and the brush in the room (M9; DESIGN §2.2 E9, E10, E16). The mat takes the slot of the room's
/// desk-surface placement ("mat": the bare room's keyboard shadow) in the hit-test order — behind the desk-front props
/// and piles, in front of the back strip — and the brush takes the brush's. The desk plane asks the mat which piles it
/// covers (no body), which it draws (lifted cloth over them) and where a landing on it tucks under; the model's mat
/// commands, Clear the Desk and Show on Desk's peek play here.
extension RoomContent {
    /// Builds and installs the mat and the brush (called once from `init`, after the desk plane).
    func installMat() {
        let mat = DeskMatElement(context: context) { [unowned self] id in elements.first { $0.id == id } }
        let brush = BrushElement(context: context) { [unowned self] in elements.first { $0.id == "brush" } }
        mat.brush = brush
        if let hub = context.physics {
            hub.isUnderMat = { [unowned mat] in mat.coversPile($0) }
            hub.drawnByMat = { [unowned mat] in mat.billboards[$0] != nil }
            hub.matLanding = { [unowned mat] in mat.landing(at: $0, count: $1) }
        }
        install([brush], inSlotOf: "brush")
        install([mat], inSlotOf: "mat")
    }

    var matElement: DeskMatElement? { extras.lazy.compactMap { $0 as? DeskMatElement }.first }
    var brushElement: BrushElement? { extras.lazy.compactMap { $0 as? BrushElement }.first }

    /// Model animations for the mat: its commands, Clear the Desk's pass, and Show on Desk's peek at a covered pile.
    func playMat(_ id: AnimationID, _ target: AnimTarget) -> Bool {
        guard let mat = matElement else { return false }
        switch (id, target) {
        case let (.matCommand, .mat(command)):
            mat.perform(command)
        case let (.clearDesk, .clearDesk(plan)):
            mat.playClearDesk(plan)
        case let (.peekMat, .location(loc)):
            if let pile = loc.pile, let p = context.state?.piles[pile], mat.coversPile(pile) { mat.peek(at: p) }
        default:
            return false
        }
        return true
    }
}

// MARK: - Scene access (demos, tests, the app)

extension DeskScene {
    /// What the mat covers, for `Visibility` and the Inventory's "Under mat".
    public var matCoverage: Visibility.Coverage {
        Visibility.Coverage(coveredPiles: room?.matElement?.coveredPiles ?? [])
    }

    /// The canvas rect of the front icon of the pile under lifted cloth (drawn by the mat) that holds `key`, if any: a
    /// press there picks up the whole pile, and the front icon is the part the lifted cloth leaves on show.
    public func matTokenRect(_ key: TokenKey) -> ArtRect? {
        guard let mat = room?.matElement else { return nil }
        for b in mat.billboards.values where b.keys.contains(key) {
            let o = b.stack.iconOrigins[0]
            return ArtRect(b.stackOrigin.x + o.x, b.stackOrigin.y + o.y, 16, 16)
        }
        return nil
    }

    /// Where the mat's parts, the brush and the keyboard are now (canvas px): `mat.center`, `mat.corner.nw|ne|se|sw`
    /// (just inside each corner), `mat.edge.n|s|e|w` (just inside each edge's middle; n is the back), `mat.flap` (a
    /// folded flap), `brush`, `keyboard`. Nil for other names, before a model, or with no flap.
    public func matAnchor(_ name: String) -> ArtRect? {
        guard let mat = room?.matElement, mat.isLive else { return nil }
        func at(_ p: SIMD2<Float>) -> ArtRect { ArtRect(Int(p.x.rounded(.down)) - 1, Int(p.y.rounded(.down)) - 1, 3, 3) }
        let c = mat.cloth, cols = c.cols, rows = c.rows
        func particle(_ col: Int, _ row: Int) -> ArtRect { at(mat.canvas(particle: c.index(col: col, row: row))) }
        // "Just inside" is a column and row in, and past the fringe and hem (8 material px) on a small mat.
        let inX = max(1, Int((8 / (c.restSize.x / Float(cols - 1))).rounded()))
        let inY = max(1, Int((8 / (c.restSize.y / Float(rows - 1))).rounded()))
        let (w, e, s, n) = (inX, cols - 1 - inX, inY, rows - 1 - inY)
        switch name {
        case "mat.center":
            return at(mat.canvas(particle: c.index(col: cols / 2, row: rows / 2)))
        case "mat.corner.sw": return particle(w, s)
        case "mat.corner.se": return particle(e, s)
        case "mat.corner.ne": return particle(e, n)
        case "mat.corner.nw": return particle(w, n)
        case "mat.edge.s": return particle(cols / 2, s)
        case "mat.edge.n": return particle(cols / 2, n)
        case "mat.edge.w": return particle(w, rows / 2)
        case "mat.edge.e": return particle(e, rows / 2)
        case "mat.flap":
            let folded = (0..<c.count).filter { c.isFolded($0) }
            guard !folded.isEmpty else { return nil }
            let mid = folded.map { mat.canvas(particle: $0) }.reduce(SIMD2<Float>.zero, +) / Float(folded.count)
            let best = folded.min { simd_length(mat.canvas(particle: $0) - mid) < simd_length(mat.canvas(particle: $1) - mid) }!
            return at(mat.canvas(particle: best))
        case "brush":
            return room?.brushElement.flatMap { $0.isLive ? $0.rect : nil }
        case "keyboard":
            return mat.keyboardRect
        default:
            return nil
        }
    }

    /// Demo expectations about the mat and the brush (`docs/DEMOS.md`): `underMat` (tokens it covers), `revealed`
    /// (tokens on show inside its rectangle: under lifted or folded cloth), `bumps` (bump groups), `bump.max` (px),
    /// `mat.folded`, `mat.asleep`, `mat.saved` (the model holds the cloth's resting pose), `mat.grab`, `mat.wrinkled`, `mat.size` (`WxD`), `mat.angle` (degrees),
    /// `mat.keyboard` (`x,d`), `mat.mode`, `mat.handles`, `brush` (`x,d`), `brush.home`, `clearDesk` (`running` or
    /// `idle`), `visible` (tokens not hidden, by the `Visibility` matrix with the mat's coverage). Nil for other keys.
    public func matExpectation(_ key: String) -> String? {
        guard let room, let mat = room.matElement, let s = deskState else { return nil }
        let c = mat.cloth
        func pair(_ p: SIMD2<Float>) -> String { "\(Int(p.x.rounded())),\(Int(p.y.rounded()))" }
        switch key {
        case "underMat": return String(mat.coveredTokens.count)
        case "revealed":
            let frame = c.baseFrame(), size = c.restSize
            let n = mat.pileViews().filter { v in
                guard !mat.coveredPiles.contains(v.id) else { return false }
                let q = frame.material(v.position)
                return q.x >= 0 && q.x <= size.x && q.y >= 0 && q.y <= size.y
            }.reduce(0) { $0 + $1.keys.count }
            return String(n)
        case "bumps": return String(mat.bumps.groups.count)
        case "bump.max": return String(Int(mat.bumps.maxHeight.rounded()))
        case "mat.folded": return String(ClothMetrics.foldedCount(c) > 0)
        case "mat.asleep": return String(c.isAsleep)
        case "mat.saved": return String(c.isAsleep && s.mat == c.matState(pattern: s.mat.pattern, mode: s.mat.mode))
        case "mat.grab": return c.grabMode?.rawValue ?? "none"
        case "mat.wrinkled": return String(ClothMetrics.wrinkle(c) > 0.25)
        case "mat.size": return "\(Int(c.restSize.x.rounded()))x\(Int(c.restSize.y.rounded()))"
        case "mat.angle": return String(Int((c.baseFrame().angle * 180 / .pi).rounded()))
        case "mat.keyboard": return c.keyboardCenter.map(pair) ?? "none"
        case "mat.mode": return mat.isFlat ? "flat" : "cloth"
        case "mat.handles": return String(mat.showsHandles)
        case "brush": return room.brushElement.map { pair($0.position) } ?? "none"
        case "brush.home": return String(room.brushElement.map { simd_length($0.position - BrushState().pos) < 1 } ?? false)
        case "clearDesk": return mat.clearRun == nil ? "idle" : "running"
        case "visible":
            let coverage = matCoverage
            let n = s.tokens.sortedKeys.filter { k in
                s.tokens.location(of: k).map { !Visibility.of($0, s, coverage).isHidden } ?? false
            }.count
            return String(n)
        default: return nil
        }
    }

    /// The mat's context menu as it would show now (tests).
    public var matMenu: MenuSpec? {
        guard let mat = room?.matElement, mat.isLive, let s = deskState else { return nil }
        return MenuSpec.mat(s, mat.menuInfo())
    }
}
