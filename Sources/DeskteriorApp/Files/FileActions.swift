import AppKit
import DeskCore
import DeskFiles
import Foundation

/// The app's half of the explicit file actions (DESIGN §3.5–§3.7, M11). It owns the session's one `FileOperator`,
/// keeps the undo records that operator issues (each redeemable once, and only on it), runs operator calls off the
/// main actor and reports what happened to the store as `.fileResult`. It never mints an intent: `EffectRunner`
/// does, right before each call (Errata 14). Where it may act follows the run mode (`FileActionScope`: the real
/// Trash only in desk mode; otherwise the FakeTrash, confined to the fixture, the state folder and a demo's source).
final class FileActions {
    let fileOperator: FileOperator
    let scope: FileActionScope
    /// Where results go (the store).
    var dispatch: (DeskAction) -> Void = { _ in }
    /// Records issued by the operator and not replayed yet, by the journal's ref.
    private var records: [Int: FileUndoRecord] = [:]
    private var nextRecord = 0
    private var whenIdle: [() -> Void] = []
    /// Operator calls under way, and how many have finished (demo idle checks and expectations).
    private(set) var inFlight = 0
    private(set) var finished = 0
    private(set) var lastFinishedAt: Date?

    init(folder: URL, stateDirectory: URL, scope: FileActionScope) throws {
        self.scope = scope
        let log = try OperationLog(directory: stateDirectory, mirrored: folder)
        fileOperator = try FileOperator(root: folder, trash: scope.trash, log: log, sandboxRoots: scope.sandboxRoots)
    }

    /// Runs one operator call and dispatches `report(result, ref)`, where `ref` names the undo record the call
    /// issued (kept here for the journal).
    func run(
        _ call: @escaping @Sendable (FileOperator) async -> FileResult,
        report: @escaping (FileResult, FileUndoRef?) -> FileReport
    ) {
        inFlight += 1
        let op = fileOperator
        Task { @MainActor [weak self] in
            let result = await call(op)
            guard let self else { return }
            let ref = keep(result.undo)
            finish(report(result, ref))
        }
    }

    /// Runs an eject and dispatches its report.
    func runEject(_ call: @escaping @Sendable (FileOperator) async -> FileOutcome) {
        inFlight += 1
        let op = fileOperator
        Task { @MainActor [weak self] in
            let outcome = await call(op)
            self?.finish(FileReport(eject: outcome))
        }
    }

    /// The record `ref` names, once: the journal entry is spent with it (the operator redeems a record once).
    func take(_ ref: FileUndoRef) -> FileUndoRecord? {
        records.removeValue(forKey: ref.id)
    }

    /// Calls `body` once no operator call is under way (now, if none is).
    func afterPending(_ body: @escaping () -> Void) {
        if inFlight == 0 { body() } else { whenIdle.append(body) }
    }

    /// Whether the system Trash is used (desk mode), where Finder's Put Back is the fallback (SPIKES S11).
    var usesSystemTrash: Bool { scope.trashFolder == nil }

    private func keep(_ record: FileUndoRecord?) -> FileUndoRef? {
        guard let record else { return nil }
        nextRecord += 1
        records[nextRecord] = record
        // The journal holds at most `UndoJournal.capacity` entries; older records can never be asked for again.
        if records.count > UndoJournal.capacity * 2, let oldest = records.keys.min() { records[oldest] = nil }
        return FileUndoRef(nextRecord)
    }

    private func finish(_ report: FileReport) {
        inFlight -= 1
        finished += 1
        lastFinishedAt = Date()
        dispatch(.fileResult(report))
        if report.toast == .usePutBack, usesSystemTrash, report.kind == .undo { Self.openTrash() }
        if inFlight == 0 {
            let waiting = whenIdle
            whenIdle = []
            for body in waiting { body() }
        }
    }

    /// Shows the Trash in Finder, where Put Back works when we may not (SPIKES S11). Opening changes nothing.
    private static func openTrash() {
        guard let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(trash)
    }
}
