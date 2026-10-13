import DeskCore
import DeskFiles
import Foundation

/// Mirrors the desktop folder into a `DeskState` (DESIGN §3.1, §4.3): loads `desk.json`, applies first-run
/// gating, scans and watches the folder, reduces every change and saves the layout (debounced 1 s, at most 5 s
/// behind a stream of changes). A scan that would remove most of the desk is confirmed by a second scan before
/// it is applied, and the layout of a folder that stops being mirrored is kept aside for its return. All of it
/// runs on a background queue; state snapshots and effects arrive on the main actor through `onState`.
///
/// Not wired into the scene yet (M5 replaces the internal reducer loop with `Store`). Reading only: nothing
/// here can change a user file.
final class MirrorController {
    struct Configuration: Sendable {
        /// The folder to mirror (already checked by `SafetyGuard`).
        var folder: URL
        var stateDirectory: URL
        var iconCacheDirectory: URL
        /// Skip first-run gating and scan at once (development modes).
        var connectImmediately: Bool
        var settings: DeskSettings
        var persistDelay: TimeInterval = 1
        /// The longest a change waits for its save while changes keep coming.
        var persistMaxWait: TimeInterval = 5
        /// How long a suspected mass removal waits for its confirming rescan.
        var confirmDelay: TimeInterval = 2
    }

    /// Called on the main actor after every change, with the effects the reducer produced (minus `.persist`).
    var onState: (DeskState, [Effect]) -> Void
    private(set) var state = DeskState()
    private let engine: MirrorEngine

    init(configuration: Configuration, onState: @escaping (DeskState, [Effect]) -> Void = { _, _ in }) {
        self.onState = onState
        engine = MirrorEngine(configuration: configuration)
        engine.publish = { [weak self] state, effects in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state = state
                    self.onState(state, effects)
                }
            }
        }
    }

    /// Loads the saved layout and, if already connected (or in a development mode), starts mirroring.
    func start() { engine.start() }

    /// Reduces `action` on the mirror queue.
    func send(_ action: DeskAction) { engine.send(action) }

    /// Rescans now (wake, session active).
    func rescan() { engine.rescan() }

    /// Saves immediately (quit, sleep, session resign) and waits for the write.
    func flush() { engine.flush() }

    func stop() { engine.stop() }

    // MARK: Launch configuration

    /// The folder, state and cache locations for `options`. Development modes must name a scratch folder
    /// (never the real desktop, inside it, or above it) and default to a temporary state directory so they
    /// cannot disturb the real layout. State and cache folders inside the mirrored folder are refused (they would
    /// show up as tokens, and every save would rescan into another save).
    static func configuration(
        options: LaunchOptions, environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleID: String = AppIdentity.bundleID
    ) throws(SafetyGuard.Refusal) -> Configuration {
        let mode: SafetyGuard.Mode = switch options.mode {
        case .desk: .desk
        case .windowed: .windowed
        case .headless: .headless
        }
        let resolution = DesktopLocator.resolve(override: options.desktopFolder, environment: environment)
        let folder = try SafetyGuard.mirrorFolder(resolution, mode: mode)
        let stateDir: URL
        let cacheDir: URL
        if let dir = options.stateDir {
            stateDir = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
            cacheDir = stateDir.appendingPathComponent("icons", isDirectory: true)
        } else if mode == .desk {
            stateDir = StateStore.defaultDirectory(bundleID: bundleID)
            cacheDir = IconCache.defaultDirectory(bundleID: bundleID)
        } else {
            stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("deskterior-\(mode.rawValue)-state")
            cacheDir = stateDir.appendingPathComponent("icons", isDirectory: true)
        }
        let realDesktop = DesktopLocator.defaultDesktopURL()
        try SafetyGuard.checkOwnFolder(stateDir, desktop: realDesktop, mirrored: folder)
        try SafetyGuard.checkOwnFolder(cacheDir, desktop: realDesktop, mirrored: folder)
        let defaults = UserDefaults(suiteName: bundleID)
        return Configuration(
            folder: folder, stateDirectory: stateDir, iconCacheDirectory: cacheDir, connectImmediately: mode != .desk,
            settings: DeskSettings(reading: { defaults?.object(forKey: $0) })
        )
    }

    /// `configuration(options:)`, or prints the refusal and exits with code 64 (DESIGN §3.7 item 7).
    static func configurationOrExit(options: LaunchOptions) -> Configuration {
        do throws(SafetyGuard.Refusal) {
            return try configuration(options: options)
        } catch {
            FileHandle.standardError.write(Data("Deskterior: \(error)\n".utf8))
            exit(error.exitCode)
        }
    }

    /// Headless entry: loads the layout from `stateDirectory` (if given), scans `folder` once, reconciles and
    /// saves. Synchronous; call it off the main thread for large folders.
    nonisolated static func mirrorOnce(
        folder: URL, stateDirectory: URL?, now: Date = Date()
    ) throws -> DeskState {
        let store = try stateDirectory.map { try StateStore(directory: $0, mirrored: folder) }
        var state = store?.load(now: now).document?.makeState() ?? DeskState()
        let snapshot = try DesktopScanner(root: folder).scan(now: now)
        try store?.switchRoot(&state, to: snapshot.rootPath, now: now)
        _ = reduce(&state, .snapshot(snapshot, now: now), ReduceEnv(now: now))
        try store?.save(state, now: now)
        return state
    }
}

/// The queue-confined half of `MirrorController`.
nonisolated final class MirrorEngine: @unchecked Sendable {
    let configuration: MirrorController.Configuration
    /// Set once by the controller before `start`.
    var publish: @Sendable (DeskState, [Effect]) -> Void = { _, _ in }

    private let queue = DispatchQueue(label: "deskterior.mirror", qos: .userInitiated)
    // Confined to `queue`.
    private var state = DeskState()
    private var store: StateStore?
    private var watcher: DesktopWatcher?
    private var volumes: VolumeWatcher?
    private var pendingSave: DispatchWorkItem?
    /// When the oldest unsaved change was scheduled.
    private var dirtySince: DispatchTime?
    /// When a suspected mass removal was first seen (its confirming rescan is due).
    private var suspectSince: DispatchTime?
    private var lastSaveError: String?
    private var started = false

    init(configuration: MirrorController.Configuration) {
        self.configuration = configuration
    }

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            do {
                store = try StateStore(directory: configuration.stateDirectory, mirrored: configuration.folder)
            } catch {
                log("state store unavailable: \(error)")
            }
            if let loaded = store?.load() {
                state = loaded.document?.makeState() ?? DeskState()
                for problem in loaded.problems { log("desk.json: \(problem)") }
                if let copy = loaded.corruptCopy { log("kept corrupt layout as \(copy.path)") }
            }
            let rootMatches = state.root.map { $0.path == DesktopLocator.canonicalPath(configuration.folder) } ?? false
            if configuration.connectImmediately || (state.access == .connected && rootMatches) {
                state.access = .connecting
                startWatching()
            } else {
                state.access = .notConnected
                if FinderPrefs.current().hidesDesktopItems && configuration.settings.showDespiteFinderHidden != true {
                    _ = reduce(&state, .finderHidesItems, env())
                }
            }
            publish(state, [.wakeLoop])

            let volumes = VolumeWatcher { [weak self] list in self?.send(.volumes(list)) }
            self.volumes = volumes
            volumes.start()
        }
    }

    func send(_ action: DeskAction) {
        queue.async { [self] in apply(action) }
    }

    func rescan() {
        queue.async { [self] in watcher?.rescanNow() }
    }

    func flush() {
        queue.sync { save() }
    }

    func stop() {
        queue.sync {
            save()
            watcher?.stop()
            watcher = nil
            volumes?.stop()
            volumes = nil
        }
    }

    // MARK: Queue-confined

    private func env() -> ReduceEnv { ReduceEnv(now: Date()) }

    private func apply(_ action: DeskAction) {
        let effects = reduce(&state, action, env())
        var forward: [Effect] = []
        for effect in effects {
            switch effect {
            case .persist: scheduleSave()
            case .connectDesktop: startWatching()
            default: forward.append(effect)
            }
        }
        if !effects.isEmpty { publish(state, forward) }
    }

    /// Starts the watcher, or rescans when it already runs (reconnecting after NO SIGNAL).
    private func startWatching() {
        if let watcher {
            watcher.rescanNow()
            return
        }
        let scanner = DesktopScanner(root: configuration.folder)
        let watcher = DesktopWatcher(scanner: scanner) { [weak self] event in
            guard let self else { return }
            queue.async { self.handle(event) }
        }
        self.watcher = watcher
        watcher.start()
    }

    private func handle(_ event: DesktopWatcher.Event) {
        switch event {
        case let .snapshot(snapshot):
            guard confirmed(snapshot) else { return }
            do {
                try store?.switchRoot(&state, to: snapshot.rootPath, now: snapshot.scannedAt)
            } catch {
                log("could not keep the previous folder's layout: \(error)")
            }
            apply(.snapshot(snapshot, now: snapshot.scannedAt))
        case let .failed(.accessDenied(path)):
            log("no access to \(path)")
            apply(.accessDenied)
        case let .failed(failure):
            // A vanished folder (iCloud Desktop toggling, unmounted volume) keeps the layout; RootChanged rescans.
            log("scan failed: \(failure)")
        }
    }

    /// False while a scan that would remove most of the desk waits for a confirming rescan (a folder being
    /// replaced, an iCloud toggle); the rescan, or any scan after `confirmDelay`, is applied.
    private func confirmed(_ snapshot: DesktopSnapshot) -> Bool {
        guard Reconciler.isMassRemoval(state, snapshot) else {
            suspectSince = nil
            return true
        }
        let now = DispatchTime.now()
        if let since = suspectSince {
            if now >= since + configuration.confirmDelay {
                suspectSince = nil
                return true
            }
            return false
        }
        suspectSince = now
        log("a scan would remove most of the desk; confirming in \(configuration.confirmDelay) s")
        let continuous = snapshot.continuous
        queue.asyncAfter(deadline: now + configuration.confirmDelay) { [weak self] in
            self?.watcher?.rescanNow(preservingContinuity: continuous)
        }
        return false
    }

    /// Debounced by `persistDelay`, but never more than `persistMaxWait` after the first unsaved change.
    private func scheduleSave() {
        pendingSave?.cancel()
        let now = DispatchTime.now()
        let first = dirtySince ?? now
        dirtySince = first
        let item = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = item
        queue.asyncAfter(
            deadline: min(now + configuration.persistDelay, first + configuration.persistMaxWait), execute: item
        )
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        dirtySince = nil
        guard let store, state.root != nil else { return }
        do {
            try store.save(state)
            lastSaveError = nil
        } catch {
            // A newer desk.json (or a full disk) fails every save; say so once.
            let message = "could not save the layout: \(error)"
            if message != lastSaveError { log(message) }
            lastSaveError = message
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("Deskterior mirror: \(message)\n".utf8))
    }
}
