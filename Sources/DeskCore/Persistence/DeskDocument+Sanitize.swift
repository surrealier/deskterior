import Foundation

// A `desk.json` that parses can still hold numbers no desk could have saved (a damaged or hand-edited file):
// a mat a mile wide, a pile far off the desk, a counter at `Int.max` that the next swish would overflow, a screen
// page in the billions. Laid out as they are, such values could crash every launch. Decoding brings each back into
// range here, before anything uses it (Errata 25); the corrupt-file fallback (§4.8) still handles files that do not
// parse at all.
extension DeskDocument {
    /// The desk plane, generously: where piles, the cup and the brush can be (the back strip is at d ≈ 120).
    static let planeX: ClosedRange<Float> = -32...544
    static let planeD: ClosedRange<Float> = -32...160
    /// The highest screen page a saved token may name (far beyond any real desk), and the largest counters kept.
    static let maxPage = 9_999
    static let maxCount = 1_000_000

    /// `self` with every out-of-range value reset to its default (or, for a token, its spot given up: it goes to
    /// the first free monitor cell when the state is made).
    public func sanitized() -> DeskDocument {
        var d = self
        let defaults = DeskDocument()
        func onPlane(_ p: SIMD2<Float>) -> Bool { p.isFinite && Self.planeX.contains(p.x) && Self.planeD.contains(p.y) }

        d.monitor.page = min(max(0, d.monitor.page), Self.maxPage)
        d.monitor.pendingNew = min(max(0, d.monitor.pendingNew), Self.maxCount)
        for (raw, drawer) in d.drawers {
            let travel = ContainerID(rawValue: raw)?.spec.travel ?? 0
            d.drawers[raw] = DrawerState(p: drawer.p.isFinite ? min(max(drawer.p, 0), Float(travel)) : 0)
        }
        if !onPlane(d.penCup.pos) { d.penCup.pos = defaults.penCup.pos }
        if !onPlane(d.brush.pos) { d.brush = defaults.brush }
        let travel = Float(CoreLayout.chairTravel.lowerBound)...Float(CoreLayout.chairTravel.upperBound)
        d.chair.x = d.chair.x.isFinite ? min(max(d.chair.x, travel.lowerBound), travel.upperBound) : defaults.chair.x
        d.wastebasket.swishes = min(max(0, d.wastebasket.swishes), Self.maxCount)
        d.flags.onboardingStep = min(max(0, d.flags.onboardingStep), 100)
        d.mat = Self.sane(d.mat)
        d.piles = d.piles.map { onPlane($0.pos) ? $0 : PileEntry(id: $0.id, pos: Placement.defaultPilePos) }
        d.tokens = d.tokens.map { t in
            var t = t
            switch t.loc {
            case let .screen(page, _, _) where page < 0 || page > Self.maxPage: t.loc = .carried
            case let .floor(x) where !FloorLine.centres.contains(x): t.loc = .carried
            default: break
            }
            return t
        }
        return d
    }

    /// The mat's frame within what the desk can hold (size within twice the transform's limits, origin near the desk,
    /// a sane angle and grid); otherwise a fresh mat in the default frame. Particles go with a frame that is reset.
    static func sane(_ m: MatState) -> MatState {
        let d = MatState()
        let grid = m.grid.count == 2 && m.grid.allSatisfy { (3...4096).contains($0) } && m.grid[0] * m.grid[1] <= 4096
        let size = m.size.isFinite && (24...600).contains(m.size.x) && (12...208).contains(m.size.y)
        let origin = m.origin.isFinite && (-320...832).contains(m.origin.x) && (-320...424).contains(m.origin.y)
        let angle = m.angle.isFinite && abs(m.angle) <= 8 * .pi
        guard grid, size, origin, angle else {
            var fresh = d
            fresh.pattern = m.pattern
            fresh.mode = m.mode
            return fresh
        }
        var out = m
        if let k = m.keyboard, !(k.isFinite && planeX.contains(k.x) && planeD.contains(k.y)) { out.keyboard = nil }
        return out
    }
}
