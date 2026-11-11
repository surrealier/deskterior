import DeskCore
import DeskFiles
import DeskScene
import Foundation

/// The Windows shell's desk (docs/WINDOWS.md WP6): the model (`DeskState` through `Reducer`), the scene host and the
/// mirror of one folder (`DesktopScanner` + `DesktopWatcher`), with the layout saved by `StateStore`.
///
/// This is the first Windows shell: it reads and arranges the desk, opens and reveals items, and keeps the layout.
/// It changes no user file: the effects that would (trash, drop-in, eject, Save as Text File, file undo) are
/// refused with a toast until the shared `DeskApp` effect runner (with its intent ledger) is extracted from the
/// macOS app.
final class WinSession {
    let host: SceneHost
    let folder: URL
    private(set) var state = DeskState()
    private var journal = UndoJournal()
    private let stateStore: StateStore?
    private var watcher: DesktopWatcher?
    /// Watcher events waiting for the main thread: the window's message loop collects them (`pump`), so delivery
    /// does not depend on the main dispatch queue being serviced.
    private let inbox = Inbox<DesktopWatcher.Event>()
    private var saveDue: Date?
    /// Opens and reveals items (the window's platform services); nil when headless.
    var platform: (any WinPlatform)?
    /// Effects refused because this shell cannot run them yet (tests, the log).
    private(set) var refusedEffects: [String] = []
    private(set) var snapshots = 0
    var log: (String) -> Void = { FileHandle.standardError.write(Data("[deskterior] \($0)\n".utf8)) }

    init(grid: PixelGrid, folder: URL, stateDirectory: URL?) throws {
        host = try SceneHost(grid: grid)
        self.folder = folder
        stateStore = try stateDirectory.map { try StateStore(directory: $0, mirrored: folder) }
        host.scene.onAction = { [weak self] in self?.dispatch($0) }
        host.scene.onRequest = { [weak self] in self?.log("scene request \($0) is not handled on Windows yet") }
    }

    /// Loads the saved layout; with `connect`, or when the saved layout was connected to this folder, starts
    /// mirroring. Otherwise the desk waits for ⏻ (the first-run card).
    func start(connect: Bool) {
        if let loaded = stateStore?.load() {
            for problem in loaded.problems { log("desk.json: \(problem)") }
            if let document = loaded.document { replace { $0 = document.makeState() } }
        }
        let rootMatches = state.root.map { $0.path == DesktopLocator.canonicalPath(folder) } ?? false
        if connect || (state.access == .connected && rootMatches) {
            replace { $0.access = .connecting }
            self.connect()
        } else {
            replace { $0.access = .notConnected }
            if FinderPrefs.current().hidesDesktopItems { dispatch(.finderHidesItems) }
        }
    }

    /// Scans once now (headless runs) and dispatches the snapshot; throws what the scanner throws.
    func scanNow() throws(DesktopScanner.Failure) {
        let snapshot = try DesktopScanner(root: folder).scan()
        received(snapshot)
    }

    /// Starts watching the folder; snapshots arrive on the main queue.
    func connect() {
        guard watcher == nil else { return }
        let inbox = inbox
        let w = DesktopWatcher(scanner: DesktopScanner(root: folder)) { event in inbox.post(event) }
        watcher = w
        w.start()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        flush()
    }

    /// Runs what is due on the main thread: watcher events, a scheduled save. The message loop calls it every pass;
    /// headless runs call it themselves.
    func pump(now: Date = Date()) {
        for event in inbox.take() { watcherEvent(event) }
        if let due = saveDue, now >= due { flush() }
    }

    private func watcherEvent(_ event: DesktopWatcher.Event) {
        switch event {
        case let .snapshot(snapshot):
            received(snapshot)
        case let .failed(.accessDenied(path)):
            log("no access to \(path)")
            dispatch(.accessDenied)
        case let .failed(failure):
            log("scan failed: \(failure)")
        }
    }

    private func received(_ snapshot: DesktopSnapshot) {
        snapshots += 1
        dispatch(.snapshot(snapshot, now: snapshot.scannedAt))
    }

    // MARK: Model

    func dispatch(_ action: DeskAction) {
        let before = state
        let t = Date()
        let env = ReduceEnv(now: t, seed: 0, utcOffset: TimeZone.current.secondsFromGMT(for: t))
        let effects = Reducer.reduce(&state, journal: &journal, action, env)
        if state != before { pushToScene() }
        for effect in effects { run(effect) }
    }

    private func replace(_ body: (inout DeskState) -> Void) {
        let before = state
        body(&state)
        if state != before { pushToScene() }
    }

    private func pushToScene() {
        host.scene.menuContext = MenuSpec.Context(
            paused: false, undo: journal.undoLabel, redo: journal.redoLabel, today: host.scene.today
        )
        host.scene.apply(state)
        host.scene.lightsMode = state.lights.mode
        host.modelChanged()
    }

    private func run(_ effect: Effect) {
        switch effect {
        case let .open(urls):
            platform?.open(urls)
        case let .reveal(urls):
            platform?.reveal(urls)
        case let .quickLook(urls):
            platform?.open(urls)                  // no Quick Look on Windows: the default app shows it
        case let .play(id, target):
            host.scene.play(id, target)
            host.modelChanged()
        case let .toast(key):
            host.scene.toast(key)
            host.modelChanged()
        case .persist:
            scheduleSave()
        case .wakeLoop:
            host.modelChanged()
        case .connectDesktop:
            connect()
        case .copy, .openPrivacySettings, .chooseFolder, .cancelFiles:
            refusedEffects.append("\(effect)")
        case .trash, .importFiles, .eject, .undoFiles, .createTextFile:
            // No file is changed by this shell (see the type's documentation).
            refusedEffects.append("\(effect)")
            log("file request not available on Windows yet: \(effect)")
            host.scene.toast(.fileFailed)
            host.modelChanged()
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        guard stateStore != nil else { return }
        saveDue = Date().addingTimeInterval(1)
    }

    func flush() {
        saveDue = nil
        guard let stateStore else { return }
        do {
            try stateStore.save(state)
        } catch {
            log("could not save the layout: \(error)")
        }
    }
}

/// A thread-safe queue of values posted from any thread and taken on the main thread.
nonisolated final class Inbox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func post(_ value: Value) { lock.withLock { values.append(value) } }

    func take() -> [Value] {
        lock.withLock {
            defer { values = [] }
            return values
        }
    }
}

/// What the window offers the session: opening and revealing items in Explorer.
protocol WinPlatform: AnyObject {
    func open(_ urls: [URL])
    func reveal(_ urls: [URL])
}
