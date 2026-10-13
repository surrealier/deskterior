import DeskCore
import Foundation

/// How to take back one file action (DESIGN §3.5 and §3.6, Undo). `FileOperator` makes it from what actually
/// happened; `FileOperator.undo` replays it with a fresh intent and re-checks every step (identity, confinement)
/// right before acting.
public struct FileUndoRecord: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Undo a trash: rename the item out of the trash back to its old place on the desk. `trashed` is nil when
        /// the trash did not say where the item went (then only Finder's Put Back can restore it).
        case putBack(trashed: URL?, original: URL, key: TokenKey)
        /// Undo a drop-in move: rename the item on the desk back to where it came from.
        case moveBack(current: URL, source: URL, key: TokenKey)
        /// Undo a drop-in copy: trash our copy.
        case trashCopy(URL, key: TokenKey)

        /// The identity the item must still have when the step runs.
        public var key: TokenKey {
            switch self {
            case let .putBack(_, _, key), let .moveBack(_, _, key), let .trashCopy(_, key): key
            }
        }
    }

    public enum Kind: String, Sendable {
        case trash, importItems
    }

    public let kind: Kind
    /// In the order the action did them; undo runs them in reverse.
    public let steps: [Step]

    public init(kind: Kind, steps: [Step]) {
        self.kind = kind
        self.steps = steps
    }
}
