import DeskCore
import DeskFiles
import Foundation

/// Debounced `frame.json` writes (Erratum 33), as `MemoSaver`: nothing until `arm()` (the session arms it once
/// `frame.json` was read and may be written), so a missing photo never replaces the user's; saved with no folder
/// connected too; a `frame.json` that turned newer or unreadable stops it for the session and `onRefusal` says so.
/// A change saves 1 s after the last one, but never more than 5 s after the first unsaved one; `flush` writes at once.
/// Other errors are logged once each, and a failed write keeps its photo for the next try, `maxWait` later.
nonisolated final class FrameSaver: @unchecked Sendable {
    let store: StateStore
    let delay: TimeInterval
    let maxWait: TimeInterval
    /// Called on the saver's queue when the photo stops being saved (the file turned newer or unreadable).
    private let onRefusal: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "deskterior.frame", qos: .utility)
    // Confined to `queue`.
    private var armed = false
    /// Outer nil: nothing pending; `.some(nil)`: write "no photo" (the frame was emptied).
    private var pending: FramePhoto??
    private var work: DispatchWorkItem?
    private var dirtySince: DispatchTime?
    private var lastError: String?
    private var saves = 0

    /// A saver over `store` (Erratum 33), unarmed.
    init(store: StateStore, delay: TimeInterval = 1, maxWait: TimeInterval = 5,
         onRefusal: (@Sendable () -> Void)? = nil) {
        self.store = store
        self.delay = delay
        self.maxWait = maxWait
        self.onRefusal = onRefusal
    }

    /// From now on changes are saved (`frame.json` was loaded and may be written).
    func arm() {
        queue.async { [self] in armed = true }
    }

    /// `arm()` has been called (and no refusal disarmed it since).
    var isArmed: Bool { queue.sync { armed } }

    /// Saves `photo` (nil: no photo) soon (ignored until armed).
    func schedule(_ photo: FramePhoto?) {
        queue.async { [self] in
            guard armed else { return }
            pending = .some(photo)
            work?.cancel()
            let now = DispatchTime.now()
            let first = dirtySince ?? now
            dirtySince = first
            let item = DispatchWorkItem { [weak self] in self?.save() }
            work = item
            queue.asyncAfter(deadline: min(now + delay, first + maxWait), execute: item)
        }
    }

    /// Writes what is pending now and waits; nothing while unarmed or with nothing to write.
    func flush() {
        queue.sync {
            guard armed else { return }
            save()
        }
    }

    /// Saves written so far.
    var saveCount: Int { queue.sync { saves } }

    private func save() {
        work?.cancel()
        work = nil
        dirtySince = nil
        guard armed, case let .some(photo) = pending else { return }
        pending = nil
        do {
            try store.saveFrame(photo)
            saves += 1
            lastError = nil
        } catch let failure as StateStore.Failure where failure.stopsFrameSaves {
            armed = false
            let line = "Deskterior: \(failure); the picture frame's photo is not saved this time\n"
            FileHandle.standardError.write(Data(line.utf8))
            onRefusal?()
        } catch {
            let message = "could not save the picture frame's photo: \(error)"
            if message != lastError { FileHandle.standardError.write(Data("Deskterior: \(message)\n".utf8)) }
            lastError = message
            // A write that failed (a full disk, a state folder briefly unwritable) keeps the photo: it is tried again
            // in `maxWait`, and a flush (quit, sleep, a folder switch) writes it. Nothing newer can have arrived since
            // `pending = nil`: `schedule` runs on this queue too.
            if case .none = pending { pending = .some(photo) }
            if work == nil {
                dirtySince = .now()
                let item = DispatchWorkItem { [weak self] in self?.save() }
                work = item
                queue.asyncAfter(deadline: .now() + maxWait, execute: item)
            }
        }
    }
}

private extension StateStore.Failure {
    /// `saveFrame` refused a file it must not write over (a newer Deskterior's, or one it cannot read).
    nonisolated var stopsFrameSaves: Bool {
        switch self {
        case .newerFrame, .frameUnreadable: true
        case .newerSchema, .writeFailed, .newerMemos, .memosUnreadable, .memosTooLarge: false
        }
    }
}
