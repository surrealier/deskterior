/// The floor line (DESIGN §2.2 E8, E11): floor tokens stand on it, stored as the core x of their **centre**
/// (`Location.floor(x:)`, `Ballistics.Landing.floor(x:)`, `WastebasketMachine.spillSpots`), and never in front of
/// the furniture standing there too (the wastebasket, the cabinet and the desk's legs; landings also keep clear of
/// where the chair stands), so a miss always ends as a visible, safe token.
public enum FloorLine {
    /// A floor token's width (core px).
    public static let tokenWidth = 16
    /// Centres that keep a token inside the core.
    public static let centres: ClosedRange<Int> = (tokenWidth / 2)...(CoreLayout.size.w - tokenWidth / 2)
    /// Core x spans of the furniture standing on the floor: the upright wastebasket, the cabinet and the desk's legs.
    public static let furniture: [Range<Int>] = [
        CoreLayout.wastebasket.minX..<CoreLayout.wastebasket.maxX, CoreLayout.cabinet.minX..<CoreLayout.cabinet.maxX,
        CoreLayout.legLeft.minX..<CoreLayout.legLeft.maxX, CoreLayout.legRight.minX..<CoreLayout.legRight.maxX,
    ]

    /// The span of the chair's base with its left edge at core x `left` (`ChairState.x`): new landings keep clear of
    /// it, so nothing lands hidden behind the wheels (the chair may still roll in front of floor tokens later).
    public static func chair(at left: Float) -> Range<Int> {
        let x = left.isFinite ? Int(left.rounded()) : CoreLayout.chair.x
        return x..<(x + CoreLayout.chair.w)
    }

    /// The floor furniture for a basket in `basket`'s state: tipped, it lies beside its upright spot
    /// (`WastebasketMachine.tippedRect`), and that spot stays clear too, so standing it back up covers nothing. A
    /// put-away cabinet leaves its span free (Erratum 30).
    public static func furniture(basket: BasketState, stowed: Set<StowID> = []) -> [Range<Int>] {
        let away = Set(stowed.compactMap { StowCatalog.spec($0).floorSpan })
        let standing = away.isEmpty ? furniture : furniture.filter { !away.contains($0) }
        let lying: ArtRect
        switch basket.state {
        case WastebasketMachine.tippedLeftName: lying = WastebasketMachine.tippedRect(right: false)
        case WastebasketMachine.tippedRightName: lying = WastebasketMachine.tippedRect(right: true)
        default: return standing
        }
        return [lying.minX..<lying.maxX] + standing
    }

    /// The spans floor tokens centred at `centres` stand on (so others land beside them).
    public static func spans(_ centres: [Int]) -> [Range<Int>] {
        centres.map { ($0 - tokenWidth / 2)..<($0 + tokenWidth / 2) }
    }

    /// Whether a token centred at `x` stands inside the core and clear of `avoiding`.
    public static func isFree(_ x: Int, avoiding: [Range<Int>] = furniture) -> Bool {
        centres.contains(x) && blocker(x, avoiding) == nil
    }

    /// The free centre nearest to core x `x` (ties go left).
    public static func freeSpot(near x: Float, avoiding: [Range<Int>] = furniture) -> Int {
        let c = x.isFinite
            ? Int(min(max(x, Float(centres.lowerBound)), Float(centres.upperBound)).rounded())
            : centres.lowerBound
        if isFree(c, avoiding: avoiding) { return c }
        let half = tokenWidth / 2
        let edges = avoiding.flatMap { [$0.lowerBound - half, $0.upperBound + half] }
            .filter { isFree($0, avoiding: avoiding) }
        return edges.min { abs($0 - c) != abs($1 - c) ? abs($0 - c) < abs($1 - c) : $0 < $1 } ?? c
    }

    /// Up to `count` free centres in a row from `start`, `pitch` apart toward `direction` (±1), stepping over
    /// anything in `avoiding`; the row ends at the core's edge.
    public static func row(
        from start: Int, direction: Int, pitch: Int, count: Int, avoiding: [Range<Int>] = furniture
    ) -> [Int] {
        let step = direction < 0 ? -max(1, pitch) : max(1, pitch), half = tokenWidth / 2
        var out: [Int] = []
        var x = start
        while out.count < count, centres.contains(x) {
            if let b = blocker(x, avoiding) {
                x = step > 0 ? b.upperBound + half : b.lowerBound - half
                continue
            }
            out.append(x)
            x += step
        }
        return out
    }

    /// The first span a token centred at `x` overlaps.
    static func blocker(_ x: Int, _ avoiding: [Range<Int>]) -> Range<Int>? {
        let half = tokenWidth / 2
        return avoiding.first { x + half > $0.lowerBound && x - half < $0.upperBound }
    }
}
