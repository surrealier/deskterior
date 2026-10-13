import Foundation

/// "A file called `name` that appears soon belongs at `location`": registered by our own operations (drops,
/// undo) so the reconciler puts the new file exactly where it was dropped (DESIGN §3.3). When the operation
/// knows the file's identity (`key` for a same-volume move, `size` for a copy) only a matching file takes the
/// hint; a name-only hint never places a file in the wastebasket.
public struct PlacementHint: Sendable, Equatable {
    /// NFC file name.
    public var name: String
    public var location: Location
    public var expires: Date
    public var key: TokenKey?
    public var size: Int64?

    public init(name: String, location: Location, expires: Date, key: TokenKey? = nil, size: Int64? = nil) {
        self.name = TextLayout.nfc(name)
        self.location = location
        self.expires = expires
        self.key = key
        self.size = size
    }

    /// Whether `entry` may take this hint.
    public func accepts(_ entry: DesktopEntry) -> Bool {
        if let key, key != entry.key { return false }
        if let size, size != entry.meta.size { return false }
        return location.container != .wastebasket || key != nil || size != nil
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

    /// True when `date` lies within the safe-save window before `now` (a clock that stepped back is not recent).
    public static func isRecent(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return (0...safeSaveWindow).contains(now.timeIntervalSince(date))
    }

    /// Name-only hints (`key`/`size` nil) for files our own operations create.
    public static func register(_ names: [String: Location], into hints: inout [PlacementHint], now: Date) {
        register(
            names.sorted(by: { $0.key < $1.key }).map {
                PlacementHint(name: $0.key, location: $0.value, expires: now.addingTimeInterval(hintLifetime))
            },
            into: &hints
        )
    }

    /// Adds `new` hints, replacing older hints for the same names.
    public static func register(_ new: [PlacementHint], into hints: inout [PlacementHint]) {
        for hint in new {
            hints.removeAll { $0.name == hint.name }
            hints.append(hint)
        }
    }

    /// Removes and returns the unexpired hint `entry` may take (names compared in NFC).
    public static func takeHint(for entry: DesktopEntry, from hints: inout [PlacementHint], now: Date) -> Location? {
        let nfc = entry.meta.displayName
        guard let i = hints.lastIndex(where: { $0.name == nfc && $0.expires > now && $0.accepts(entry) }) else {
            return nil
        }
        return hints.remove(at: i).location
    }

    /// Drops expired hints, tombstones and reconcile memory; returns how many tombstones went.
    @discardableResult
    public static func expire(_ state: inout DeskState, now: Date) -> Int {
        state.hints.removeAll { $0.expires <= now }
        state.memory.expire(now: now)
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

    /// Forgets positions of piles that hold no token (and that no carried token was picked up from).
    public static func pruneEmptyPiles(_ state: inout DeskState) {
        let used = Set(state.tokens.piles).union(state.tokens.originPiles)
        state.piles = state.piles.filter { used.contains($0.key) }
    }
}
