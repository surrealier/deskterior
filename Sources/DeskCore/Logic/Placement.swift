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
    /// Where a new pile the file starts stands on the desk plane (a drop on the bare desk; DESIGN §3.6).
    public var pilePos: SIMD2<Float>?
    /// A drop's hint while its operation runs (M11): the dropped item's path where it came from, which its result
    /// names (`FileReport.Placed.source`).
    public var source: String?
    /// False for a drop whose name is taken already (on the desk, or earlier in the drop): the item lands under
    /// another name (" 2"), so a file appearing under this one is someone else's (a safe-save) and never takes it;
    /// the result places the item by its identity.
    public var matchesName: Bool

    public init(
        name: String, location: Location, expires: Date, key: TokenKey? = nil, size: Int64? = nil,
        pilePos: SIMD2<Float>? = nil, source: String? = nil, matchesName: Bool = true
    ) {
        self.name = TextLayout.nfc(name)
        self.location = location
        self.expires = expires
        self.key = key
        self.size = size
        self.pilePos = pilePos
        self.source = source
        self.matchesName = matchesName
    }

    /// Whether `entry` may take this hint.
    public func accepts(_ entry: DesktopEntry) -> Bool {
        guard matchesName else { return false }
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

    /// Removes and returns the location of the unexpired hint `entry` may take (names compared in NFC).
    public static func takeHint(for entry: DesktopEntry, from hints: inout [PlacementHint], now: Date) -> Location? {
        takeHintEntry(for: entry, from: &hints, now: now)?.location
    }

    /// Removes and returns the unexpired hint `entry` may take (names compared in NFC).
    public static func takeHintEntry(for entry: DesktopEntry, from hints: inout [PlacementHint], now: Date) -> PlacementHint? {
        let nfc = entry.meta.displayName
        guard let i = hints.lastIndex(where: { $0.name == nfc && $0.expires > now && $0.accepts(entry) }) else {
            return nil
        }
        return hints.remove(at: i)
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
    /// nearest free one on its page; the container if it is below its hard cap (a put-away one's stand-in,
    /// `awaySubstitute`); the pile if it exists (or can be recreated at `pilePos`); otherwise the first free cell.
    /// Cells handed out are taken in `allocator`, whose occupancy must mirror `state.tokens`.
    public static func resolve(
        _ preferred: Location?, pilePos: SIMD2<Float>? = nil, in state: inout DeskState,
        allocator: inout ScreenGrid.Allocator
    ) -> Location {
        switch preferred {
        // MARK: tidy (0.3.0)
        case let .container(id, _)? where state.isAway(id):
            guard let sub = awaySubstitute(for: id, in: state) else { break }
            return .container(sub, order: state.tokens.count(in: sub))
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

// MARK: tidy (0.3.0)

extension Placement {
    /// Where a returning file (a tombstone, a hint, an undo) aimed at the put-away container `id` goes instead
    /// (Erratum 30): the first of the riser drawers, the cabinet drawers and a face-down phone that is out, below
    /// its hard cap and hidden now, so a hidden file stays hidden; nil for a shown place (the memo clips) or when
    /// there is none (then the monitor).
    public static func awaySubstitute(for id: ContainerID, in s: DeskState) -> ContainerID? {
        guard id.spec.concealment != .shown else { return nil }
        return concealing.first { c in
            let hidden = c == .phone ? s.phone.faceDown : s.drawerOpening(c) < Visibility.drawerPeek
            return hidden && !s.isAway(c) && s.tokens.count(in: c) < c.spec.hardCap
        }
    }

    /// The places that hide what is inside them once shut, in the order a returning file looks for one.
    static let concealing: [ContainerID] = [.riserLeft, .riserRight, .cabinetTop, .cabinetMiddle, .cabinetFile, .phone]
}
