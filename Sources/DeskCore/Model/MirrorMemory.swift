import Foundation

/// What the reconciler remembers between scans for a few seconds (runtime only, never persisted):
///
/// - **renames**: the name a token was renamed away from, so a backup-style save (`doc.txt` → `doc.txt~`, write
///   a new `doc.txt`, delete `doc.txt~`) seen half-way still keeps the place;
/// - **swaps**: a new file that arrived while such a renamed token was still there, waiting to take its place;
/// - **aliases**: old keys of re-keyed tokens, so a gesture that began before a safe-save still finds its token.
public struct MirrorMemory: Sendable, Equatable {
    struct Rename: Sendable, Equatable {
        var name: Reconciler.NameKind
        var key: TokenKey
        var at: Date
    }

    struct Swap: Sendable, Equatable {
        /// The renamed token (the backup) whose place `new` takes when it vanishes.
        var old: TokenKey
        var new: TokenKey
        /// Where `new` arrived; it moves only if it is still there.
        var at: Location
        var until: Date
    }

    struct Alias: Sendable, Equatable {
        var old: TokenKey
        var new: TokenKey
    }

    /// Aliases kept (newest win); enough for any gesture in flight.
    static let maxAliases = 64

    var renames: [Rename] = []
    var swaps: [Swap] = []
    private(set) var aliases: [Alias] = []

    public init() {}

    /// `key` after following recent re-keys (itself when it was never re-keyed).
    public func current(_ key: TokenKey) -> TokenKey {
        var k = key
        for _ in 0..<Self.maxAliases {
            guard let a = aliases.last(where: { $0.old == k }) else { return k }
            k = a.new
        }
        return k
    }

    mutating func alias(_ old: TokenKey, to new: TokenKey) {
        aliases.removeAll { $0.old == old }
        aliases.append(Alias(old: old, new: new))
        if aliases.count > Self.maxAliases { aliases.removeFirst(aliases.count - Self.maxAliases) }
    }

    /// Forgets renames older than the safe-save window and swaps past their deadline.
    mutating func expire(now: Date) {
        renames.removeAll { !Placement.isRecent($0.at, now: now) }
        swaps.removeAll { $0.until < now }
    }
}
