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
    /// The reconciler moved a token: a backup-style save took over the cell of the file it replaced.
    case moved(TokenKey, to: Location)
    /// Other metadata changed (size, dates, tags, kind…).
    case updated(TokenKey)
    /// The mirrored folder changed; the layout started over.
    case reset
}

/// Pure snapshot diff (DESIGN §3.1 item 5, §3.2, §3.3): `(state, snapshot, hints, now) → (state', events)`.
///
/// Matching order for each file:
/// 1. its key (volume + inode), unless the key now names a different file (kind and creation date both
///    changed: a reused inode on FAT, exFAT or SMB);
/// 2. a hint from our own operations; a tombstone with its key (left for step 4); then safe-save swaps, only in
///    a `continuous` scan: a token that vanished in this batch under the same NFC name + kind is re-keyed in
///    place, as is one renamed away from that name moments ago (backup-style save). While the renamed token is
///    still present the newcomer arrives as new, and takes its place if it vanishes within the window;
/// 3. (removals become tombstones; a carried token leaves its origin);
/// 4. tombstones: by key; by NFC name + kind when the removal was within `Placement.safeSaveWindow` or the size
///    and creation date agree; otherwise the file is new and takes the first free monitor cell from HDMI 1.
///
/// Name-only matches never put a file in the wastebasket, whose contents Empty Wastebasket trashes. New files
/// are placed in name order, so a burst lays out (and prints in) predictably.
public enum Reconciler {
    /// A scan that would remove more than this share of the tokens (and more than `suspectMinimum`) is suspect:
    /// the folder may be mid-replacement, so the caller should rescan before committing it.
    public static let suspectShare = 0.5
    public static let suspectMinimum = 20

    /// True when applying `snapshot` would remove a suspiciously large part of the desk.
    public static func isMassRemoval(_ state: DeskState, _ snapshot: DesktopSnapshot) -> Bool {
        guard let root = state.root, root.path == snapshot.rootPath, state.tokens.count > suspectMinimum else {
            return false
        }
        let present = Set(snapshot.entries.map(\.key))
        let gone = state.tokens.records.keys.reduce(0) { present.contains($1) ? $0 : $0 + 1 }
        return gone > suspectMinimum && Double(gone) > Double(state.tokens.count) * suspectShare
    }

    private enum Plan {
        /// Our own operation's hint, with the spot of a new pile it starts.
        case hint(Location, SIMD2<Float>?)
        /// Arrives as new and takes the renamed token `partner`'s place if it vanishes soon.
        case swap(partner: TokenKey)
        case unmatched
    }

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
            state.memory = MirrorMemory()
            state.monitor.page = 0
            events.append(.reset)
        }
        state.root = DesktopRoot(path: snapshot.rootPath, volume: snapshot.rootVolume)
        // In a continuous scan, whatever vanished did so within one watcher batch before `now`.
        let removedAt: Date? = snapshot.continuous ? now : nil

        // One entry per key (hard links share an inode; the first name wins).
        var seen = Set<TokenKey>()
        let entries = snapshot.entries.filter { seen.insert($0.key).inserted }

        // 1. Known keys: metadata updates (a rename keeps the location).
        var fresh: [DesktopEntry] = []
        var reused = Set<TokenKey>()
        for entry in entries {
            guard let old = state.tokens.meta(of: entry.key) else {
                fresh.append(entry)
                continue
            }
            guard Identity.plausible(kind: old.kind, created: old.created, entry.meta) else {
                reused.insert(entry.key)
                fresh.append(entry)
                continue
            }
            guard old != entry.meta else { continue }
            state.tokens.updateMeta(entry.key, entry.meta)
            if old.displayName != entry.meta.displayName {
                events.append(.renamed(entry.key, from: old.name, to: entry.meta.name))
                if snapshot.continuous { state.memory.renames.append(.init(name: NameKind(old), key: entry.key, at: now)) }
            } else {
                events.append(.updated(entry.key))
            }
        }
        fresh.sort { ScreenGrid.nameOrder(($0.key, $0.meta), ($1.key, $1.meta)) }
        var vanished = Set(state.tokens.records.keys.filter { !seen.contains($0) }).union(reused)

        // 2. Same-batch matches.
        var stonesByKey: [TokenKey: Tombstone] = [:]
        for t in state.tombstones { stonesByKey[t.key] = t }
        var vanishedByName: [NameKind: [TokenKey]] = [:]
        if snapshot.continuous {
            for key in vanished.sorted() where !reused.contains(key) {
                vanishedByName[NameKind(state.tokens.meta(of: key)!), default: []].append(key)
            }
        }
        func allowsNameMatch(_ key: TokenKey) -> Bool {
            state.tokens.restingLocation(of: key)?.container != .wastebasket
        }
        func rekey(_ old: TokenKey, _ entry: DesktopEntry) -> Bool {
            guard state.tokens.rekey(old, to: entry.key, meta: entry.meta) else { return false }
            vanished.remove(old)
            state.memory.alias(old, to: entry.key)
            for i in state.memory.swaps.indices {
                if state.memory.swaps[i].old == old { state.memory.swaps[i].old = entry.key }
                if state.memory.swaps[i].new == old { state.memory.swaps[i].new = entry.key }
            }
            events.append(.rekeyed(from: old, to: entry.key))
            return true
        }
        var planned: [(DesktopEntry, Plan)] = []
        for entry in fresh {
            let nk = NameKind(entry.meta)
            if let hint = Placement.takeHintEntry(for: entry, from: &state.hints, now: now) {
                planned.append((entry, .hint(hint.location, hint.pilePos)))
                continue
            }
            if reused.contains(entry.key) {
                planned.append((entry, .unmatched))
                continue
            }
            if let stone = stonesByKey[entry.key], Identity.plausible(kind: stone.kind, created: stone.created, entry.meta) {
                planned.append((entry, .unmatched))
                continue
            }
            if let old = vanishedByName[nk]?.first(where: { vanished.contains($0) && allowsNameMatch($0) }), rekey(old, entry) {
                continue
            }
            if let r = state.memory.renames.lastIndex(where: { $0.name == nk && Placement.isRecent($0.at, now: now) }) {
                let partner = state.memory.renames[r].key
                if state.tokens.contains(partner), allowsNameMatch(partner) {
                    state.memory.renames.remove(at: r)
                    if vanished.contains(partner) {
                        if rekey(partner, entry) { continue }
                    } else {
                        planned.append((entry, .swap(partner: partner)))
                        continue
                    }
                }
            }
            planned.append((entry, .unmatched))
        }

        // 3. Removals leave tombstones (7 days, persisted) with the places they had before this batch; a carried
        //    token leaves its origin. A backup-style save waiting on the token takes over its place.
        if !vanished.isEmpty { state.tombstones.removeAll { vanished.contains($0.key) } }
        let gone = vanished.sorted().map { ($0, state.tokens[$0]!, state.tokens.restingLocation(of: $0)!) }
        for (key, record, loc) in gone {
            state.tokens.remove(key)
            if loc != .carried {
                state.tombstones.append(Tombstone(
                    key: key, name: record.meta.name, kind: record.meta.kind, loc: loc,
                    until: now.addingTimeInterval(Tombstone.lifetime), pilePos: loc.pile.flatMap { state.piles[$0] },
                    removedAt: removedAt, size: record.meta.size, created: record.meta.created
                ))
            }
            events.append(.removed(key, loc, name: record.meta.name))
            if let i = state.memory.swaps.firstIndex(where: { $0.old == key }) {
                let swap = state.memory.swaps.remove(at: i)
                if loc != .carried, state.tokens.location(of: swap.new) == swap.at,
                   state.tokens.move(swap.new, to: loc, grid: grid)
                {
                    events.append(.moved(swap.new, to: state.tokens.location(of: swap.new)!))
                }
            }
        }
        if state.tombstones.count > Tombstone.maxCount {
            // Screen places are cheap to lose; hidden ones are what the user cannot find again.
            state.tombstones.sort { a, b in
                (a.loc.isScreen ? 0 : 1, a.until, a.key) < (b.loc.isScreen ? 0 : 1, b.until, b.key)
            }
            state.tombstones.removeFirst(state.tombstones.count - Tombstone.maxCount)
        }
        Placement.pruneEmptyPiles(&state)

        // 4. Arrivals. Those with a remembered place go first so new files cannot take their cells.
        var stones = TombstoneIndex(state.tombstones)
        var placed: [(DesktopEntry, Location?, SIMD2<Float>?, DeskEvent.Arrival)] = []
        var newcomers: [DesktopEntry] = []
        var partners: [TokenKey: TokenKey] = [:]
        for (entry, plan) in planned {
            switch plan {
            case let .hint(loc, pilePos):
                placed.append((entry, loc, pilePos, .hint))
            case let .swap(partner):
                partners[entry.key] = partner
                newcomers.append(entry)
            case .unmatched:
                if let (stone, arrival) = stones.take(for: entry, now: now) {
                    placed.append((entry, stone.loc, stone.pilePos, arrival))
                } else {
                    newcomers.append(entry)
                }
            }
        }
        state.tombstones = stones.remaining
        placed += newcomers.map { ($0, nil, nil, .new) }

        var allocator = ScreenGrid.Allocator(grid: grid, occupied: state.tokens.occupiedCells)
        for (entry, preferred, pilePos, arrival) in placed {
            let loc = Placement.resolve(preferred, pilePos: pilePos, in: &state, allocator: &allocator)
            if state.tokens.insert(entry.key, meta: entry.meta, at: loc, grid: grid) {
                let at = state.tokens.location(of: entry.key)!
                events.append(.added(entry.key, at, arrival))
                if let partner = partners[entry.key] {
                    state.memory.swaps.append(.init(
                        old: partner, new: entry.key, at: at, until: now.addingTimeInterval(Placement.safeSaveWindow)
                    ))
                }
            }
        }
        Placement.pruneEmptyPiles(&state)
        // A tombstone never outlives the return of its key.
        if !state.tombstones.isEmpty { state.tombstones.removeAll { state.tokens.contains($0.key) } }

        state.monitor.page = min(state.monitor.page, state.pageCount(grid: grid) - 1)
        return events
    }

    /// Identity checks beyond the key.
    enum Identity {
        /// False when a key now names a different file: its kind and its creation date both changed.
        static func plausible(kind: FileKind, created: Date?, _ meta: TokenMeta) -> Bool {
            guard let a = created, let b = meta.created else { return true }
            return kind == meta.kind || sameInstant(a, b)
        }

        /// Same size and creation date: the removed file brought back as a copy.
        static func corroborates(_ stone: Tombstone, _ meta: TokenMeta) -> Bool {
            guard let size = stone.size, size == meta.size, let a = stone.created, let b = meta.created else {
                return false
            }
            return sameInstant(a, b)
        }

        static func sameInstant(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.001 }
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

    /// Tombstones indexed for one pass: by key first, then by NFC name and kind, newest first.
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

        /// The tombstone `entry` returns to, and how: by key (a plausible same file); by name when the removal was
        /// recent (`.safeSave`) or size and creation date agree (`.restored`); never by name into the wastebasket.
        mutating func take(for entry: DesktopEntry, now: Date) -> (Tombstone, DeskEvent.Arrival)? {
            if let i = byKey[entry.key], !taken.contains(i),
               Identity.plausible(kind: stones[i].kind, created: stones[i].created, entry.meta)
            {
                taken.insert(i)
                return (stones[i], .restored)
            }
            for i in byName[NameKind(entry.meta)] ?? [] where !taken.contains(i) {
                let stone = stones[i]
                guard stone.key != entry.key, stone.loc.container != .wastebasket else { continue }
                if Placement.isRecent(stone.removedAt, now: now) {
                    taken.insert(i)
                    return (stone, .safeSave)
                }
                if Identity.corroborates(stone, entry.meta) {
                    taken.insert(i)
                    return (stone, .restored)
                }
            }
            return nil
        }

        var remaining: [Tombstone] {
            stones.indices.filter { !taken.contains($0) }.map { stones[$0] }
        }
    }
}
