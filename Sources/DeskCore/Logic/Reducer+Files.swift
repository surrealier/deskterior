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
            let t = trashTargets(s, keys)
            return t.urls.isEmpty ? [] : [.trash(t.urls, expected: t.keys, confirm: nil)]
        case .requestEmptyWastebasket:
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
        default:
            return []
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
    /// there (journaled as a move); the others are announced by name hints (with a new pile's spot) and moved or
    /// copied in. The app passes desk items spelled under the model's root.
    static func dropIn(_ s: inout DeskState, _ d: DropIn, _ env: ReduceEnv) -> [Effect] {
        guard s.access == .connected, let root = s.root, !d.urls.isEmpty else { return [] }
        let rootPath = URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path
        var byName: [String: TokenKey] = [:]
        for key in s.tokens.sortedKeys {
            if let meta = s.tokens.meta(of: key), byName[meta.name] == nil { byName[meta.name] = key }
        }
        var onDesk: [TokenKey] = []
        var outside: [URL] = []
        for url in d.urls {
            let u = url.standardizedFileURL
            guard u.deletingLastPathComponent().path == rootPath else {
                outside.append(url)
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
            Placement.register(outside.map {
                PlacementHint(name: $0.lastPathComponent, location: d.location, expires: expires, pilePos: d.pilePos)
            }, into: &s.hints)
            var hints: [String: Location] = [:]
            for url in outside { hints[TextLayout.nfc(url.lastPathComponent)] = d.location }
            effects.append(.importFiles(outside, op: d.op, hints: hints))
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

    /// Applies what a file effect did: trashed tokens leave now; dropped files' hints follow the names they landed
    /// under (with their identity, so a hint may even place one in the wastebasket); a toast says what did not happen.
    static func applyFileResult(_ s: inout DeskState, _ r: FileReport, _ env: ReduceEnv) -> [Effect] {
        var effects: [Effect] = []
        switch r.kind {
        case .trash, .emptyWastebasket:
            effects += removeTrashed(&s, r.trashed, now: env.now, grid: env.grid)
        case .importItems:
            followDropped(&s, r, now: env.now)
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

    /// Re-aims the drop's name hints at what actually landed: an item renamed on arrival (" 2") takes the hint
    /// under its new name, every landed item's hint learns its identity, and refused items' hints go.
    static func followDropped(_ s: inout DeskState, _ r: FileReport, now: Date) {
        let expires = now.addingTimeInterval(Placement.hintLifetime)
        var moved: [PlacementHint] = []
        for p in r.placed {
            let source = TextLayout.nfc(p.source)
            guard let hint = s.hints.last(where: { $0.name == source }) else { continue } // the mirror was faster
            s.hints.removeAll { $0.name == source }
            moved.append(PlacementHint(
                name: p.name, location: hint.location, expires: expires, key: p.key, size: hint.size,
                pilePos: hint.pilePos
            ))
        }
        for name in r.refusedNames {
            let nfc = TextLayout.nfc(name)
            s.hints.removeAll { $0.name == nfc }
        }
        Placement.register(moved, into: &s.hints)
    }
}
