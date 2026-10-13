import Foundation

/// What a reconcile pass changed, in the order the scene should show it.
public enum DeskEvent: Sendable, Equatable {
    public enum Arrival: String, Sendable {
        /// A new file: first free monitor cell.
        case new
        /// Placed by one of our own operations' hints.
        case hint
        /// Back from a tombstone, at its old place.
        case restored
        /// The same name came back within the safe-save window: silently the same token.
        case safeSave
    }

    case added(TokenKey, Location, Arrival)
    case removed(TokenKey, Location, name: String)
    case renamed(TokenKey, from: String, to: String)
    /// A safe-save swap inside one batch: the token keeps its place under a new key.
    case rekeyed(from: TokenKey, to: TokenKey)
    /// Other metadata changed (size, dates, tags, kind…).
    case updated(TokenKey)
    /// The mirrored folder changed; the layout started over.
    case reset
}

/// Pure snapshot diff (DESIGN §3.1 item 5, §3.2, §3.3): `(state, snapshot, hints, now) → (state', events)`.
///
/// Matching order for each file: its key (volume + inode); then, for files that vanished in the same batch,
/// NFC name + kind (safe-save swap: the token is re-keyed in place); then hints, tombstones by key, a
/// tombstone of the same NFC name + kind younger than `Placement.safeSaveWindow`, older tombstones by name;
/// otherwise the file is new and takes the first free monitor cell from HDMI 1. New files are placed in name
/// order, so a burst lays out (and prints in) predictably.
public enum Reconciler {
    @discardableResult
    public static func reconcile(
        _ state: inout DeskState, _ snapshot: DesktopSnapshot, now: Date, grid: ScreenGrid = .standard
    ) -> [DeskEvent] {
        var events: [DeskEvent] = []
        Placement.expire(&state, now: now)

        if let root = state.root, root.path != snapshot.rootPath {
            state.tokens = TokenStore()
            state.tombstones = []
            state.piles = [:]
            state.monitor.page = 0
            events.append(.reset)
        }
        state.root = DesktopRoot(path: snapshot.rootPath, volume: snapshot.rootVolume)

        // One entry per key (hard links share an inode; the first name wins).
        var seen = Set<TokenKey>()
        let entries = snapshot.entries.filter { seen.insert($0.key).inserted }

        // 1. Known keys: metadata updates (a rename keeps the location).
        var fresh: [DesktopEntry] = []
        for entry in entries {
            guard let old = state.tokens.meta(of: entry.key) else {
                fresh.append(entry)
                continue
            }
            if old != entry.meta {
                state.tokens.updateMeta(entry.key, entry.meta)
                events.append(old.name != entry.meta.name
                    ? .renamed(entry.key, from: old.name, to: entry.meta.name) : .updated(entry.key))
            }
        }
        fresh.sort { ScreenGrid.nameOrder(($0.key, $0.meta), ($1.key, $1.meta)) }
        var vanished = state.tokens.sortedKeys.filter { !seen.contains($0) }

        // 2. Safe-save swaps within this batch: same NFC name and kind, new key.
        var vanishedByName: [NameKind: [TokenKey]] = [:]
        for key in vanished { vanishedByName[NameKind(state.tokens.meta(of: key)!), default: []].append(key) }
        var unmatched: [DesktopEntry] = []
        for entry in fresh {
            let nk = NameKind(entry.meta)
            if let old = vanishedByName[nk]?.first, state.tokens.rekey(old, to: entry.key, meta: entry.meta) {
                vanishedByName[nk]!.removeFirst()
                events.append(.rekeyed(from: old, to: entry.key))
            } else {
                unmatched.append(entry)
            }
        }
        let rekeyed = Set(events.compactMap { if case let .rekeyed(old, _) = $0 { old } else { nil } })
        vanished.removeAll { rekeyed.contains($0) }

        // 3. Removals leave tombstones (7 days, persisted) with the places they had before this batch.
        let before = vanished.map { state.tokens[$0]! }
        for (key, record) in zip(vanished, before) {
            state.tokens.remove(key)
            state.tombstones.removeAll { $0.key == key }
            if record.location != .carried {
                state.tombstones.append(Tombstone(
                    key: key, name: record.meta.name, kind: record.meta.kind, loc: record.location,
                    until: now.addingTimeInterval(Tombstone.lifetime), pilePos: record.location.pile.flatMap { state.piles[$0] }
                ))
            }
            events.append(.removed(key, record.location, name: record.meta.name))
        }
        if state.tombstones.count > Tombstone.maxCount {
            state.tombstones.sort { $0.until < $1.until }
            state.tombstones.removeFirst(state.tombstones.count - Tombstone.maxCount)
        }
        Placement.pruneEmptyPiles(&state)

        // 4. Arrivals. Those with a remembered place go first so new files cannot take their cells.
        var stones = TombstoneIndex(state.tombstones)
        var placed: [(DesktopEntry, Location?, SIMD2<Float>?, DeskEvent.Arrival)] = []
        var newcomers: [DesktopEntry] = []
        for entry in unmatched {
            if let loc = Placement.takeHint(named: entry.meta.name, from: &state.hints, now: now) {
                placed.append((entry, loc, nil, .hint))
            } else if let stone = stones.take(for: entry) {
                let recent = now.timeIntervalSince(stone.removedAt) <= Placement.safeSaveWindow
                let arrival: DeskEvent.Arrival = stone.key != entry.key && recent ? .safeSave : .restored
                placed.append((entry, stone.loc, stone.pilePos, arrival))
            } else {
                newcomers.append(entry)
            }
        }
        state.tombstones = stones.remaining
        placed += newcomers.map { ($0, nil, nil, .new) }

        var allocator = ScreenGrid.Allocator(grid: grid, occupied: state.tokens.occupiedCells)
        for (entry, preferred, pilePos, arrival) in placed {
            let loc = Placement.resolve(preferred, pilePos: pilePos, in: &state, allocator: &allocator)
            if state.tokens.insert(entry.key, meta: entry.meta, at: loc, grid: grid) {
                events.append(.added(entry.key, state.tokens.location(of: entry.key)!, arrival))
            }
        }
        Placement.pruneEmptyPiles(&state)

        state.monitor.page = min(state.monitor.page, state.pageCount(grid: grid) - 1)
        return events
    }

    /// Matching key for safe-save swaps and tombstones. `String` equality and hashing already follow canonical
    /// equivalence, so NFD and NFC spellings of a name match.
    struct NameKind: Hashable {
        let name: String
        let kind: FileKind

        init(_ meta: TokenMeta) {
            name = meta.displayName
            kind = meta.kind
        }

        init(_ stone: Tombstone) {
            name = TextLayout.nfc(stone.name)
            kind = stone.kind
        }
    }

    /// Tombstones indexed for one pass: by key first, then the newest with the same NFC name and kind.
    struct TombstoneIndex {
        private var stones: [Tombstone]
        private var byKey: [TokenKey: Int] = [:]
        private var byName: [NameKind: [Int]] = [:]
        private var taken = Set<Int>()

        init(_ stones: [Tombstone]) {
            self.stones = stones
            for (i, t) in stones.enumerated() {
                byKey[t.key] = i
                byName[NameKind(t), default: []].append(i)
            }
            for k in byName.keys { byName[k]!.sort { stones[$0].until > stones[$1].until } }
        }

        mutating func take(for entry: DesktopEntry) -> Tombstone? {
            if let i = byKey[entry.key], taken.insert(i).inserted { return stones[i] }
            guard let list = byName[NameKind(entry.meta)], let i = list.first(where: { !taken.contains($0) }) else {
                return nil
            }
            taken.insert(i)
            return stones[i]
        }

        var remaining: [Tombstone] {
            stones.indices.filter { !taken.contains($0) }.map { stones[$0] }
        }
    }
}
