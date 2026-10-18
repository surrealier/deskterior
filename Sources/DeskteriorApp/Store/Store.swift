import DeskCore
import DeskFiles
import Foundation

/// The single owner of the desk model (DESIGN §4.3), on the main actor. Every change is `dispatch(action)` →
/// `Reducer.reduce` with the undo journal → observers get the new state (`SceneSync` first, so the scene shows it)
/// → the effects run (`EffectRunner`). `.persist` effects become debounced saves on a background queue
/// (`LayoutSaver`: 1 s, at most 5 s behind a stream of changes); quitting flushes. The memos (notes, day pages, the
/// D-Day) follow the model into `memos.json` the same way (`MemoSaver`, armed once they were loaded; Erratum 31). The
/// mirror, the icon renderer and the scene all reach the model only through here.
final class Store {
    private(set) var state: DeskState
    private(set) var journal = UndoJournal()
    /// Deterministic randomness for the reducer (`--seed`).
    var seed: UInt64 = 0
    var now: () -> Date = Date.init
    /// Runs every effect but `.persist`, after observers have seen the state that produced it.
    var effects: ((Effect) -> Void)?
    /// Just before the reducer sees an action (app-side bookkeeping such as remembering "Show anyway").
    var willDispatch: ((DeskAction, DeskState) -> Void)?
    /// The undo or redo label changed (menus show "Undo <label>"), even when the state did not.
    var journalChanged: (() -> Void)?
    let saver: LayoutSaver?
    // MARK: memos (0.3.0)
    let memoSaver: MemoSaver?
    private var observers: [(id: Int, body: (DeskState, DeskState) -> Void)] = []
    private var nextObserver = 0
    /// Actions dispatched so far (demo idle detection, tests).
    private(set) var dispatchCount = 0

    init(state: DeskState = DeskState(), saver: LayoutSaver? = nil, memoSaver: MemoSaver? = nil) {
        self.state = state
        self.saver = saver
        self.memoSaver = memoSaver
    }

    /// Calls `body(new, old)` after every change; returns a token for `removeObserver`.
    @discardableResult
    func observe(_ body: @escaping (DeskState, DeskState) -> Void) -> Int {
        nextObserver += 1
        observers.append((nextObserver, body))
        return nextObserver
    }

    func removeObserver(_ id: Int) {
        observers.removeAll { $0.id == id }
    }

    func dispatch(_ action: DeskAction) {
        dispatchCount += 1
        willDispatch?(action, state)
        let before = state
        let labels = (journal.undoLabel, journal.redoLabel, journal.undoStack.count, journal.redoStack.count)
        let out = Reducer.reduce(&state, journal: &journal, action, ReduceEnv(now: now(), seed: seed))
        if state != before { notify(before) }
        // MARK: memos (0.3.0): every change to the memos is saved, an undo or redo included; a load (`replace`) never.
        if state.memos != before.memos { memoSaver?.schedule(state.memos) }
        if labels != (journal.undoLabel, journal.redoLabel, journal.undoStack.count, journal.redoStack.count) {
            journalChanged?()
        }
        for effect in out {
            if effect == .persist {
                saver?.schedule(state)
            } else {
                effects?(effect)
            }
        }
    }

    /// Changes the model outside the reducer (loading `desk.json` and `memos.json`, a folder switch that parks the old
    /// layout). Nothing is saved for it.
    func replace(_ body: (inout DeskState) throws -> Void) rethrows {
        let before = state
        try body(&state)
        if state != before { notify(before) }
    }

    /// Saves now and waits (quit, sleep, session resign): the layout, and the memos' pending change if there is one.
    func flush() {
        saver?.flush(state)
        memoSaver?.flush()
    }

    var undoLabel: String? { journal.undoLabel }
    var redoLabel: String? { journal.redoLabel }

    private func notify(_ before: DeskState) {
        for o in observers { o.body(state, before) }
    }
}

/// Debounced `desk.json` writes on a background queue (DESIGN §4.8): a change saves 1 s after the last one, but
/// never more than 5 s after the first unsaved one; `flush` writes at once. Errors are logged once each.
nonisolated final class LayoutSaver: @unchecked Sendable {
    let store: StateStore
    let delay: TimeInterval
    let maxWait: TimeInterval
    private let queue = DispatchQueue(label: "deskterior.save", qos: .utility)
    // Confined to `queue`.
    private var pending: DeskState?
    private var work: DispatchWorkItem?
    private var dirtySince: DispatchTime?
    private var lastError: String?
    private var saves = 0

    init(store: StateStore, delay: TimeInterval = 1, maxWait: TimeInterval = 5) {
        self.store = store
        self.delay = delay
        self.maxWait = maxWait
    }

    func schedule(_ state: DeskState) {
        queue.async { [self] in
            pending = state
            work?.cancel()
            let now = DispatchTime.now()
            let first = dirtySince ?? now
            dirtySince = first
            let item = DispatchWorkItem { [weak self] in self?.save() }
            work = item
            queue.asyncAfter(deadline: min(now + delay, first + maxWait), execute: item)
        }
    }

    /// Writes `state` (or what is pending) now and waits.
    func flush(_ state: DeskState? = nil) {
        queue.sync {
            if let state { pending = state }
            save()
        }
    }

    /// Saves written so far.
    var saveCount: Int { queue.sync { saves } }

    private func save() {
        work?.cancel()
        work = nil
        dirtySince = nil
        guard let state = pending, state.root != nil else { return }
        pending = nil
        do {
            try store.save(state)
            saves += 1
            lastError = nil
        } catch {
            let message = "could not save the layout: \(error)"
            if message != lastError { FileHandle.standardError.write(Data("Deskterior: \(message)\n".utf8)) }
            lastError = message
        }
    }
}
