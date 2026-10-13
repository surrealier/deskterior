import Foundation

/// "A file called `name` that appears soon belongs at `location`": registered by our own operations (drops,
/// undo) so the reconciler puts the new file exactly where it was dropped (DESIGN §3.3).
public struct PlacementHint: Sendable, Equatable {
    /// NFC file name.
    public var name: String
    public var location: Location
    public var expires: Date

    public init(name: String, location: Location, expires: Date) {
        self.name = TextLayout.nfc(name)
        self.location = location
        self.expires = expires
    }
}

/// Where tokens go: new-file placement, hints, restore targets and parade order.
public enum Placement {
    public static let hintLifetime: TimeInterval = 10
    /// A file reappearing under the same name within this window is the same file (safe-save swap).
    public static let safeSaveWindow: TimeInterval = 2
    /// Desk-plane spot for a pile created without a position (the scene corrects it with `pilesSettled`).
    public static let defaultPilePos: SIMD2<Float> = [256, 48]
    /// Spacing of several tokens dropped on the floor at once.
    public static let floorSpacing = 18

    public static func register(_ names: [String: Location], into hints: inout [PlacementHint], now: Date) {
        for (name, location) in names.sorted(by: { $0.key < $1.key }) {
            let hint = PlacementHint(name: name, location: location, expires: now.addingTimeInterval(hintLifetime))
            hints.removeAll { $0.name == hint.name }
            hints.append(hint)
        }
    }

    /// Removes and returns the unexpired hint for `name` (compared in NFC).
    public static func takeHint(named name: String, from hints: inout [PlacementHint], now: Date) -> Location? {
        let nfc = TextLayout.nfc(name)
        guard let i = hints.lastIndex(where: { $0.name == nfc && $0.expires > now }) else { return nil }
        return hints.remove(at: i).location
    }

    /// Drops expired hints and tombstones; returns how many tombstones went.
    @discardableResult
    public static func expire(_ state: inout DeskState, now: Date) -> Int {
        state.hints.removeAll { $0.expires <= now }
        let before = state.tombstones.count
        state.tombstones.removeAll { $0.until <= now }
        return before - state.tombstones.count
    }

    /// A location `state` can take right now, as close to `preferred` as possible: the preferred cell or the
    /// nearest free one on its page; the container if it is below its hard cap; the pile if it exists (or can
    /// be recreated at `pilePos`); otherwise the first free cell. Cells handed out are taken in `allocator`,
    /// whose occupancy must mirror `state.tokens`.
    public static func resolve(
        _ preferred: Location?, pilePos: SIMD2<Float>? = nil, in state: inout DeskState,
        allocator: inout ScreenGrid.Allocator
    ) -> Location {
        switch preferred {
        case let .screen(page, col, row)?:
            let c = allocator.grid.nearestFree(to: ScreenCell(page: page, col: col, row: row), allocator.occupied)
            allocator.take(c)
            return c.location
        case let .container(id, order)? where state.tokens.count(in: id) < id.spec.hardCap:
            return .container(id, order: min(max(order, 0), state.tokens.count(in: id)))
        case let .desk(pile, order)?:
            if state.piles[pile] != nil {
                return .desk(pile: pile, order: min(max(order, 0), state.tokens.members(of: pile).count))
            }
            if let pilePos {
                state.piles[pile] = pilePos
                return .desk(pile: pile, order: 0)
            }
        case let .floor(x)?:
            return .floor(x: x)
        default:
            break
        }
        return allocator.next().location
    }

    /// `keys` sorted by display name (Finder-like), then key.
    public static func byName(_ keys: [TokenKey], in store: TokenStore) -> [TokenKey] {
        keys.compactMap { k in store.meta(of: k).map { (key: k, meta: $0) } }
            .sorted(by: ScreenGrid.nameOrder)
            .map(\.key)
    }

    /// Forgets positions of piles that hold no token.
    public static func pruneEmptyPiles(_ state: inout DeskState) {
        let used = Set(state.tokens.piles)
        state.piles = state.piles.filter { used.contains($0.key) }
    }
}
