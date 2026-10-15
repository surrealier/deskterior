import Foundation

/// The explicit file actions (DESIGN §3.5–§3.7, M11): requests become file effects, and what `FileOperator` did
/// comes back as `.fileResult`. Only request actions emit file effects; the reducer never decides on its own that
/// a file should change. Files are named by their tokens' URLs while the mirror is current, each with the identity
/// it must still have (`FileOperator` re-checks it right before acting).
extension Reducer {
    /// How long a drop's name hints wait for the operation to finish (a long copy); its result re-aims them at the
    /// names the files landed under for `Placement.hintLifetime`, or drops them.
    public static let dropHintLifetime: TimeInterval = 120

    static func reduceFiles(_ s: inout DeskState, _ a: DeskAction, _ env: ReduceEnv) -> [Effect] {
        switch a {
        case let .requestTrash(keys):
            if let toast = unavailable(s), !keys.isEmpty { return [.toast(toast)] }
            let t = trashTargets(s, keys)
            return t.urls.isEmpty ? [] : [.trash(t.urls, expected: t.keys, confirm: nil)]
        case .requestEmptyWastebasket:
            if let toast = unavailable(s), s.tokens.count(in: .wastebasket) > 0 { return [.toast(toast)] }
            return emptyWastebasket(s)
        case let .requestEject(id):
            guard let v = s.volumes.first(where: { $0.id == id }), v.isEjectable else { return [] }
            return [.eject(v.path)]
        case let .requestOpenVolume(id):
            return s.volumes.first { $0.id == id }.map { [.open([URL(fileURLWithPath: $0.path, isDirectory: true)])] } ?? []
        case let .requestRevealVolume(id):
            return s.volumes.first { $0.id == id }.map { [.reveal([URL(fileURLWithPath: $0.path, isDirectory: true)])] } ?? []
        case let .importDropped(urls, at, op):
            return dropIn(&s, DropIn(urls: urls, location: at, op: op), env)
        case let .requestDropIn(d):
            return dropIn(&s, d, env)
        case let .fileResult(report):
            return applyFileResult(&s, report, env)
        case .fileStarted:
            return [] // The journal's (`Reducer.reduce(_:journal:_:_:)`).
        default:
            return []
        }
    }

    /// Why no file can change now (the desk folder is not connected), as a toast; nil when connected.
    static func unavailable(_ s: DeskState) -> ToastKey? {
        switch s.access {
        case .connected: nil
        case .denied: .accessDenied
        case .notConnected, .finderHidden, .connecting: .filesUnavailable
        }
    }

    // MARK: Requests

    /// The live tokens among `keys` (following re-keys, each once) that have a file now, with their URLs.
    static func trashTargets(_ s: DeskState, _ keys: [TokenKey]) -> (urls: [URL], keys: [TokenKey]) {
        var seen = Set<TokenKey>()
        var urls: [URL] = []
        var out: [TokenKey] = []
        for key in keys.map(s.currentKey) where seen.insert(key).inserted {
            guard let url = s.url(of: key) else { continue }
            urls.append(url)
            out.append(key)
        }
        return (urls, out)
    }

    /// Empty Wastebasket… (E8): everything in the basket, after a sheet listing how many and the first names
    /// (`MenuSpec.listLimit`, by name). The basket never empties itself.
    static func emptyWastebasket(_ s: DeskState) -> [Effect] {
        let t = trashTargets(s, s.tokens.members(of: .wastebasket))
        guard !t.urls.isEmpty else { return [] }
        let names = Placement.byName(t.keys, in: s.tokens).prefix(MenuSpec.listLimit)
            .compactMap { s.tokens.meta(of: $0)?.displayName }
        return [.trash(t.urls, expected: t.keys, confirm: .emptyWastebasket(names: names, more: t.keys.count - names.count))]
    }

    /// A drop onto a desk spot (DESIGN §3.6): items whose folder is the desk folder are tokens already and only move
    /// there (journaled as a move); the others are announced by hints (with a new pile's spot), one per item by
    /// its path (an app's alias by its name without ".app", Erratum 29), and moved, copied or aliased in, each with
    /// its own op (`DropIn.ops`). A hint whose name is taken already (by a desk item, another drop still
    /// waiting, or an item earlier in this drop; compared as the desk's case-insensitive volume does) is never
    /// taken by name: that item lands as " 2", and a file appearing under the old name is someone else's (an
    /// editor's safe-save); its result places it by identity. The app passes desk items spelled under the model's
    /// root.
    static func dropIn(_ s: inout DeskState, _ d: DropIn, _ env: ReduceEnv) -> [Effect] {
        if let toast = unavailable(s), !d.urls.isEmpty { return [.toast(toast)] }
        guard let root = s.root, !d.urls.isEmpty else { return [] }
        let rootPath = URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path
        var byName: [String: TokenKey] = [:]
        for key in s.tokens.sortedKeys {
            if let meta = s.tokens.meta(of: key), byName[meta.name] == nil { byName[meta.name] = key }
        }
        var onDesk: [TokenKey] = []
        var outside: [URL] = []
        var ops: [ImportOp] = []
        for (i, url) in d.urls.enumerated() {
            let u = url.standardizedFileURL
            guard u.deletingLastPathComponent().path == rootPath else {
                outside.append(url)
                ops.append(d.op(at: i))
                continue
            }
            // A desk item the mirror has not seen yet is left to it.
            if let key = byName[u.lastPathComponent] ?? s.tokens.sortedKeys.first(where: {
                s.tokens.meta(of: $0)?.displayName == TextLayout.nfc(u.lastPathComponent)
            }) {
                onDesk.append(key)
            }
        }
        var effects: [Effect] = []
        if !onDesk.isEmpty { effects += placeDropped(&s, onDesk, d, env) }
        if !outside.isEmpty {
            let expires = env.now.addingTimeInterval(dropHintLifetime)
            var taken = Set(s.tokens.sortedKeys.compactMap { s.tokens.meta(of: $0).map { folded($0.displayName) } })
            taken.formUnion(s.hints.filter { $0.source != nil && $0.matchesName }.map { folded($0.name) })
            var hints: [String: Location] = [:]
            for (url, op) in zip(outside, ops) {
                let path = url.standardizedFileURL.path
                // An app's alias lands without ".app" (Erratum 29).
                let name = TextLayout.nfc(DropIn.landingName(url.lastPathComponent, op: op))
                s.hints.removeAll { $0.source == path }
                s.hints.append(PlacementHint(
                    name: name, location: d.location, expires: expires, pilePos: d.pilePos, source: path,
                    matchesName: taken.insert(folded(name)).inserted
                ))
                hints[name] = d.location
            }
            effects.append(.importFiles(outside, ops: ops, hints: hints))
        }
        return effects
    }

    /// Desk items dropped back onto the desk: the same move a carry there would make.
    private static func placeDropped(_ s: inout DeskState, _ keys: [TokenKey], _ d: DropIn, _ env: ReduceEnv) -> [Effect] {
        switch d.location {
        case let .desk(pile, _):
            if let at = d.pilePos ?? s.piles[pile] { return reducePhysics(&s, .dropOnDesk(keys, pile: pile, at: at), env) }
            return reduce(&s, .move(keys, to: d.location), env)
        case let .floor(x):
            return reducePhysics(&s, .dropOnFloor(keys, x: x), env)
        default:
            return reduce(&s, .move(keys, to: d.location), env)
        }
    }

    // MARK: Results

    /// A file name as the desk's volume compares it: NFC, case folded.
    static func folded(_ name: String) -> String { TextLayout.nfc(name).lowercased() }

    /// Applies what a file effect did: trashed tokens leave now; dropped files' hints follow the names they landed
    /// under (with their identity, so a hint may even place one in the wastebasket); a toast says what did not happen,
    /// or what an undo did.
    static func applyFileResult(_ s: inout DeskState, _ r: FileReport, _ env: ReduceEnv) -> [Effect] {
        var effects: [Effect] = []
        switch r.kind {
        case .trash, .emptyWastebasket:
            effects += removeTrashed(&s, r.trashed, now: env.now, grid: env.grid)
        case .importItems:
            effects += followDropped(&s, r, env)
        case .undo, .eject:
            break
        }
        if let toast = r.toast { effects.append(.toast(toast)) }
        return effects
    }

    /// Takes trashed tokens off the desk at once, as the mirror would a moment later: a poof where each was (a
    /// handle wiggle for a container), and a tombstone with its place, so an undo brings it back there.
    static func removeTrashed(_ s: inout DeskState, _ keys: [TokenKey], now: Date, grid: ScreenGrid) -> [Effect] {
        var effects: [Effect] = []
        var seen = Set<TokenKey>()
        for key in keys.map(s.currentKey) where seen.insert(key).inserted {
            guard let record = s.tokens[key], let loc = s.tokens.restingLocation(of: key) else { continue }
            let pilePos = loc.pile.flatMap { s.piles[$0] }
            s.tokens.remove(key)
            s.tombstones.removeAll { $0.key == key }
            if loc != .carried {
                s.tombstones.append(Tombstone(
                    key: key, name: record.meta.name, kind: record.meta.kind, loc: loc,
                    until: now.addingTimeInterval(Tombstone.lifetime), pilePos: pilePos, removedAt: now,
                    size: record.meta.size, created: record.meta.created
                ))
            }
            effects.append(loc.container.map { .play(.handleWiggle, .container($0)) } ?? .play(.poof, .location(loc)))
        }
        guard !effects.isEmpty else { return [] }
        Placement.pruneEmptyPiles(&s)
        s.monitor.page = min(s.monitor.page, s.pageCount(grid: grid) - 1)
        return effects + [.persist, .wakeLoop]
    }

    /// Re-aims the drop's hints (found by each item's source path) at what actually landed: an item renamed on
    /// arrival (" 2") takes its hint under its new name, with its identity, for `Placement.hintLifetime`; refused
    /// items' hints go. An item the mirror placed already without its hint (its name was taken, or a name-only hint
    /// never fills the wastebasket) moves from the monitor to its drop spot now, by identity.
    static func followDropped(_ s: inout DeskState, _ r: FileReport, _ env: ReduceEnv) -> [Effect] {
        let expires = env.now.addingTimeInterval(Placement.hintLifetime)
        var effects: [Effect] = []
        for p in r.placed {
            guard let i = s.hints.lastIndex(where: { $0.source == p.source }) else { continue } // taken by name already
            let hint = s.hints.remove(at: i)
            if let key = p.key, s.tokens.contains(key) {
                if s.tokens.location(of: key)?.isScreen == true {
                    let spot = DropIn(urls: [], location: hint.location, pilePos: hint.pilePos, op: .move)
                    effects += placeDropped(&s, [key], spot, env)
                }
                continue
            }
            let name = TextLayout.nfc(p.name)
            s.hints.removeAll { $0.name == name && $0.source == nil }
            s.hints.append(PlacementHint(
                name: name, location: hint.location, expires: expires, key: p.key, size: hint.size, pilePos: hint.pilePos
            ))
        }
        for path in r.refused { s.hints.removeAll { $0.source == path } }
        return effects
    }
}
