import AppKit
import DeskCore
import DeskFiles
import Foundation

/// The app's half of the explicit file actions (DESIGN §3.5–§3.7, M11). It owns the session's one `FileOperator`,
/// keeps the undo records that operator issues (each redeemable once, and only on it), runs operator calls off the
/// main actor and reports what happened to the store as `.fileResult`. It never mints an intent: `EffectRunner`
/// does, right before each call (Errata 14). Where it may act follows the run mode (`FileActionScope`: the real
/// Trash only in desk mode; otherwise the FakeTrash, confined to the fixture, the state folder and a demo's source).
///
/// Every call ⌘Z can take back gets its ref when it starts, and the store hears `.fileStarted` at once, so the
/// journal keeps the place the action was asked in; its report fills that entry. A drop-in's copy can be stopped
/// (`cancel`, ⌘Z while it runs) and shows its progress over the monitor once it takes a while.
final class FileActions {
    let fileOperator: FileOperator
    let scope: FileActionScope
    /// Where results go (the store).
    var dispatch: (DeskAction) -> Void = { _ in }
    /// Shows a progress line over the monitor (nil takes it down); set by the session.
    var showProgress: (String?) -> Void = { _ in }
    /// Records issued by the operator and not replayed yet, by the journal's ref, with the kind of action each takes
    /// back.
    private var records: [Int: (record: FileUndoRecord, kind: FileReport.Kind)] = [:]
    /// Calls under way, by ref (cancelled through their task).
    private var running: [Int: Task<Void, Never>] = [:]
    private var lastRef = 0
    private var whenDone: [Int: [() -> Void]] = [:]
    /// Operator calls under way, and how many have finished (demo idle checks and expectations).
    private(set) var inFlight = 0
    private(set) var finished = 0
    private(set) var lastFinishedAt: Date?
    /// The ref of the newest call started (a caller that just dispatched a request finds its call by it).
    private(set) var lastStarted: FileUndoRef?

    /// A copy shows progress after this long, and updates it at most this often.
    static let progressDelay: TimeInterval = 0.5
    static let progressInterval: TimeInterval = 0.25

    init(folder: URL, stateDirectory: URL, scope: FileActionScope) throws {
        self.scope = scope
        let log = try OperationLog(directory: stateDirectory, mirrored: folder)
        fileOperator = try FileOperator(root: folder, trash: scope.trash, log: log, sandboxRoots: scope.sandboxRoots)
    }

    // MARK: Calls

    /// Runs one operator call ⌘Z can take back (a trash, Empty Wastebasket, a drop-in with `op`): the journal takes
    /// its place now (`.fileStarted`), and `report(result, undo)` fills it, where `undo` names the record the call
    /// issued (kept here). `call` gets a progress sink for a copy. Returns the call's ref.
    @discardableResult
    func run(
        _ kind: FileReport.Kind, op: ImportOp? = nil,
        _ call: @escaping @Sendable (FileOperator, (@Sendable (FileOperator.CopyProgress) -> Void)?) async -> FileResult,
        report: @escaping (FileResult, FileUndoRef?) -> FileReport
    ) -> FileUndoRef {
        let ref = nextRef()
        dispatch(.fileStarted(ref, kind, op: op))
        let progress = kind == .importItems ? progressSink(ref) : nil
        start(ref) { [weak self] op in
            let result = await call(op, progress)
            guard let self else { return nil }
            if let record = result.undo { keep(record, kind, as: ref) }
            var r = report(result, result.undo == nil ? nil : ref)
            r.ticket = ref
            return r
        }
        return ref
    }

    /// Replays the record `ref` names (⌘Z), with the intent `call` spends. A record refused before anything ran
    /// (a stale intent) is kept, and the journal entry is ready again; otherwise it is spent.
    func runUndo(_ ref: FileUndoRef, _ call: @escaping @Sendable (FileOperator, FileUndoRecord) async -> FileResult) {
        guard let kept = records.removeValue(forKey: ref.id) else {
            inFlight += 1
            finish(FileReport(kind: .undo, count: 1, problems: [.expired], ticket: ref), ref: nil)
            return
        }
        start(ref) { [weak self] op in
            let result = await call(op, kept.record)
            let again = FileReport.recordKept(result)
            if again { self?.records[ref.id] = kept }
            return FileReport(undo: result, of: kept.kind, ticket: ref, kept: again)
        }
    }

    /// An undo that never reached the operator (no intent could be minted): its journal entry is ready again.
    func undoNotRun(_ ref: FileUndoRef) {
        dispatch(.fileResult(FileReport(kind: .undo, count: 1, problems: [.failed], ticket: ref, kept: true)))
    }

    /// Runs an eject and dispatches its report (nothing to undo).
    func runEject(_ call: @escaping @Sendable (FileOperator) async -> FileOutcome) {
        start(nextRef()) { op in FileReport(eject: await call(op)) }
    }

    /// Stops the call `ref` names, if it is still running (a drop-in's copy: items not started stay where they are).
    func cancel(_ ref: FileUndoRef) {
        running[ref.id]?.cancel()
    }

    // MARK: Waiting

    /// Calls `body` once the call `ref` names has reported (now, if it is not running).
    func whenFinished(_ ref: FileUndoRef, _ body: @escaping () -> Void) {
        if running[ref.id] == nil { body() } else { whenDone[ref.id, default: []].append(body) }
    }

    /// Whether the system Trash is used (desk mode), where Finder's Put Back is the fallback (SPIKES S11).
    var usesSystemTrash: Bool { scope.trashFolder == nil }

    // MARK: Inside

    private func nextRef() -> FileUndoRef {
        lastRef += 1
        let ref = FileUndoRef(lastRef)
        lastStarted = ref
        return ref
    }

    /// Runs `body` on the operator in a task of its own (cancellable by `ref`), then reports what it returns.
    private func start(_ ref: FileUndoRef, _ body: @escaping (FileOperator) async -> FileReport?) {
        inFlight += 1
        let op = fileOperator
        running[ref.id] = Task { @MainActor [weak self] in
            let report = await body(op)
            guard let self else { return }
            if let report { finish(report, ref: ref) } else { inFlight -= 1 }
        }
    }

    private func keep(_ record: FileUndoRecord, _ kind: FileReport.Kind, as ref: FileUndoRef) {
        records[ref.id] = (record, kind)
        // The journal holds at most `UndoJournal.capacity` entries; older records can never be asked for again.
        if records.count > UndoJournal.capacity * 2, let oldest = records.keys.min() { records[oldest] = nil }
    }

    private func finish(_ report: FileReport, ref: FileUndoRef?) {
        inFlight -= 1
        finished += 1
        lastFinishedAt = Date()
        if let ref {
            running[ref.id] = nil
            progressCounts[ref.id] = nil
            progressStarted[ref.id] = nil
            progressShownAt[ref.id] = nil
            if progressShown.remove(ref.id) != nil { showProgress(nil) }
        }
        dispatch(.fileResult(report))
        if report.toast == .usePutBack, usesSystemTrash { Self.openTrash() }
        if let ref, let waiting = whenDone.removeValue(forKey: ref.id) { for body in waiting { body() } }
    }

    /// Shows the Trash in Finder, where Put Back works when we may not (SPIKES S11). Opening changes nothing.
    private static func openTrash() {
        guard let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(trash)
    }

    // MARK: Progress

    /// Copies whose progress line is up, by ref.
    private var progressShown: Set<Int> = []
    private var progressCounts: [Int: Int] = [:]
    private var progressStarted: [Int: Date] = [:]
    private var progressShownAt: [Int: Date] = [:]

    /// A sink the operator calls (off the main actor) as a copy starts each file or folder.
    private func progressSink(_ ref: FileUndoRef) -> @Sendable (FileOperator.CopyProgress) -> Void {
        { [weak self] _ in
            Task { @MainActor in self?.progressed(ref) }
        }
    }

    /// One more item started: once the copy has run `progressDelay`, the line over the monitor says how many so far
    /// and that ⌘Z stops it.
    private func progressed(_ ref: FileUndoRef) {
        guard running[ref.id] != nil else { return }
        let now = Date()
        let n = progressCounts[ref.id, default: 0] + 1
        progressCounts[ref.id] = n
        let started = progressStarted[ref.id] ?? now
        progressStarted[ref.id] = started
        guard now.timeIntervalSince(started) >= Self.progressDelay else { return }
        if let at = progressShownAt[ref.id], now.timeIntervalSince(at) < Self.progressInterval { return }
        progressShownAt[ref.id] = now
        progressShown.insert(ref.id)
        showProgress(Self.progressLine(n))
    }

    /// "Copying 37 files… ⌘Z stops".
    static func progressLine(_ items: Int) -> String {
        "Copying \(items) \(items == 1 ? "item" : "items")… ⌘Z stops"
    }
}
