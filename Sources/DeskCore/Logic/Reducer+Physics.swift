/// The desk-plane actions (DESIGN §2.1 DropResolver, §2.2 E7, E8, E11; M7): drops on the bare desk, and the pen
/// cup's and the wastebasket's Tip Over / Stand Up, which the scene plays and then commits.
extension Reducer {
    static func reducePhysics(_ s: inout DeskState, _ a: DeskAction, _ env: ReduceEnv) -> [Effect] {
        switch a {
        case let .dropOnDesk(keys, pile, at):
            return dropOnDesk(&s, keys.map(s.currentKey), pile: pile, at: at, grid: env.grid)
        case let .tipOver(id) where id == .penCup || id == .wastebasket:
            return [.play(.tipOver, .container(id)), .wakeLoop]
        case let .standUp(id) where id == .penCup || id == .wastebasket:
            return [.play(.standUp, .container(id)), .wakeLoop]
        default:
            return []
        }
    }

    /// Puts `keys` on top of `pile`. A pile that is new, or that every one of its tokens leaves for itself, is (re)made
    /// at `at`; an existing pile stays where it is. Refuses non-finite or off-desk points.
    static func dropOnDesk(_ s: inout DeskState, _ keys: [TokenKey], pile: PileID, at: SIMD2<Float>, grid: ScreenGrid) -> [Effect] {
        let desk = DeskPlanePhysics.desk
        guard at.isFinite, at.x >= desk.x, at.x <= desk.x + desk.width, at.y >= desk.d, at.y <= desk.d + desk.depth
        else { return [] }
        var seen = Set<TokenKey>()
        let movers = keys.filter { s.tokens.contains($0) && seen.insert($0).inserted }
        guard !movers.isEmpty else { return [] }
        let before = movers.map { s.tokens.location(of: $0)! }
        let oldPos = s.piles[pile]
        let staying = s.tokens.members(of: pile).filter { !seen.contains($0) }
        for k in movers { s.tokens.move(k, to: .carried) }
        if s.piles[pile] == nil || staying.isEmpty { s.piles[pile] = at }
        let start = s.tokens.members(of: pile).count
        for (i, k) in movers.enumerated() { s.tokens.move(k, to: .desk(pile: pile, order: start + i), grid: grid) }
        Placement.pruneEmptyPiles(&s)
        s.monitor.page = min(s.monitor.page, s.pageCount(grid: grid) - 1)
        let after = movers.map { s.tokens.location(of: $0)! }
        return after == before && s.piles[pile] == oldPos ? [] : [.persist, .wakeLoop]
    }

    /// Floor centres for `count` tokens set down at core x `x` (`FloorLine`): a row 18 px apart from the free spot
    /// nearest `x`, stepping over the basket (where it stands or lies), the cabinet and the tokens already there
    /// (`occupied`, their centres), continuing on the other side when the floor ends; tokens that still do not fit
    /// share the last spot.
    public static func floorSpots(near x: Int, count: Int, basket: BasketState = BasketState(), occupied: [Int] = []) -> [Int] {
        guard count > 0 else { return [] }
        let avoid = FloorLine.furniture(basket: basket) + FloorLine.spans(occupied)
        let start = FloorLine.freeSpot(near: Float(x), avoiding: avoid)
        let pitch = Placement.floorSpacing
        var spots = FloorLine.row(from: start, direction: 1, pitch: pitch, count: count, avoiding: avoid)
        if spots.count < count {
            spots += FloorLine.row(from: start - pitch, direction: -1, pitch: pitch, count: count - spots.count, avoiding: avoid)
        }
        while spots.count < count { spots.append(spots.last ?? start) }
        return spots
    }
}

extension DeskState {
    /// `count` fresh pile ids (`makePileID` and the ones after it), for a scene that makes several piles at once.
    public func makePileIDs(_ count: Int) -> [PileID] {
        guard count > 0 else { return [] }
        let first = makePileID()
        guard let n = Int(first.raw.dropFirst()) else { return [first] }
        return (0..<count).map { PileID("P\(n + $0)") }
    }
}
