import DeskCore
import Foundation

/// How to take back one file action (DESIGN §3.5 and §3.6, Undo): an opaque handle. Only `FileOperator` makes one,
/// from what actually happened, and `FileOperator.undo` replays only records it issued, once each, with a fresh
/// intent, re-checking every step (identity, confinement) right before acting.
public struct FileUndoRecord: Sendable, Equatable {
    enum Step: Sendable, Equatable {
        /// Undo a trash: rename the item out of the trash back to its old place on the desk. `trashed` is nil when
        /// the trash did not say where the item went (then only Finder's Put Back can restore it).
        case putBack(trashed: URL?, original: URL, key: TokenKey)
        /// Undo a drop-in move: rename the item on the desk back to where it came from.
        case moveBack(current: URL, source: URL, key: TokenKey)
        /// Undo a drop-in copy: trash our copy.
        case trashCopy(URL, key: TokenKey)
        // MARK: alias (Erratum 29)
        /// Undo a drop-in alias: trash our alias file (what it points to is never touched).
        case trashAlias(URL, key: TokenKey)
        // MARK: files (0.3.0)
        /// Undo Save as Text File on Desktop (Erratum 31): trash the file we wrote, only while it is still exactly as
        /// written (its identity, size and modification date); a file the user edited or swapped stays.
        case trashCreated(URL, key: TokenKey, size: Int64, modified: Date)

        /// The identity the item must still have when the step runs.
        var key: TokenKey {
            switch self {
            case let .putBack(_, _, key), let .moveBack(_, _, key), let .trashCopy(_, key), let .trashAlias(_, key),
                 let .trashCreated(_, key, _, _):
                key
            }
        }
    }

    public enum Kind: String, Sendable {
        case trash, importItems
        // MARK: files (0.3.0)
        /// Save as Text File on Desktop. Not named `createFile`: the file-safety lint keeps that word to the writers.
        case createTextFile
    }

    public let kind: Kind
    /// In the order the action did them; undo runs them in reverse.
    let steps: [Step]
    let id = UUID()

    init(kind: Kind, steps: [Step]) {
        self.kind = kind
        self.steps = steps
    }

    /// Where the aliases this record takes back lie (the undo's report tells them from copies by it).
    var aliases: Set<URL> {
        Set(steps.compactMap { if case let .trashAlias(url, _) = $0 { url } else { nil } })
    }

    // MARK: files (0.3.0)

    /// The identity a text file this record would trash was written with, when it lies at `url`.
    func createdKey(at url: URL) -> TokenKey? {
        for case let .trashCreated(u, key, _, _) in steps where u == url { return key }
        return nil
    }
}
