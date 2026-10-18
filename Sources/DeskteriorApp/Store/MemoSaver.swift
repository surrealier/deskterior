import DeskCore
import DeskFiles
import Foundation

/// Debounced `memos.json` writes on a background queue (Erratum 31), like `LayoutSaver`: a change saves 1 s after the
/// last one, but never more than 5 s after the first unsaved one; `flush` writes at once. Nothing is written until
/// `arm()`: the session arms it only once `memos.json` was read and may be written (`StateStore.MemosLoaded.writable`,
/// false for a newer Deskterior's file), so an empty book can never replace the user's notes, not before the load and
/// not over a newer file. Unlike the layout, the notes are saved with no folder connected too (they are not about the
/// folder). Errors are logged once each; a `memos.json` that turned newer or unreadable during the session disarms it
/// for the rest of the session, as the load would have.
nonisolated final class MemoSaver: @unchecked Sendable {
    let store: StateStore
    let delay: TimeInterval
    let maxWait: TimeInterval
    private let queue = DispatchQueue(label: "deskterior.memos", qos: .utility)
    // Confined to `queue`.
    private var armed = false
    private var pending: MemoBook?
    private var work: DispatchWorkItem?
    private var dirtySince: DispatchTime?
    private var lastError: String?
    private var saves = 0

    init(store: StateStore, delay: TimeInterval = 1, maxWait: TimeInterval = 5) {
        self.store = store
        self.delay = delay
        self.maxWait = maxWait
    }

    /// From now on changes are saved (the book was loaded and its file may be written).
    func arm() {
        queue.async { [self] in armed = true }
    }

    /// `arm()` has been called.
    var isArmed: Bool { queue.sync { armed } }

    /// Saves `book` soon (ignored until armed).
    func schedule(_ book: MemoBook) {
        queue.async { [self] in
            guard armed else { return }
            pending = book
            work?.cancel()
            let now = DispatchTime.now()
            let first = dirtySince ?? now
            dirtySince = first
            let item = DispatchWorkItem { [weak self] in self?.save() }
            work = item
            queue.asyncAfter(deadline: min(now + delay, first + maxWait), execute: item)
        }
    }

    /// Writes `book` (or what is pending) now and waits; nothing while unarmed or with nothing to write.
    func flush(_ book: MemoBook? = nil) {
        queue.sync {
            guard armed else { return }
            if let book { pending = book }
            save()
        }
    }

    /// Saves written so far.
    var saveCount: Int { queue.sync { saves } }

    private func save() {
        work?.cancel()
        work = nil
        dirtySince = nil
        guard armed, let book = pending else { return }
        pending = nil
        do {
            try store.saveMemos(book)
            saves += 1
            lastError = nil
        } catch let failure as StateStore.Failure where failure.stopsMemoSaves {
            armed = false
            FileHandle.standardError.write(Data("Deskterior: \(failure); memo changes are not saved this time\n".utf8))
        } catch {
            let message = "could not save the memos: \(error)"
            if message != lastError { FileHandle.standardError.write(Data("Deskterior: \(message)\n".utf8)) }
            lastError = message
        }
    }
}

private extension StateStore.Failure {
    /// `saveMemos` refused a file it must not write over (a newer Deskterior's, or one it cannot read).
    nonisolated var stopsMemoSaves: Bool {
        switch self {
        case .newerMemos, .memosUnreadable: true
        case .newerSchema, .writeFailed: false
        }
    }
}
