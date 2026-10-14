import DeskCore
import DeskFiles
import Foundation

/// Mirrors the desktop folder into the `Store` (DESIGN §3.1, §4.3). It loads `desk.json` into the store, applies
/// first-run gating (connect prompt, or the DESKTOP HIDDEN card when Finder hides desktop items), and runs the
/// scanner, watcher and volume watcher on background queues (`MirrorEngine`); snapshots, access failures and
/// volumes come back to the main actor and reach the model as actions. Its safety behaviours stay here:
///
/// - a scan that would remove most of the desk is held and confirmed by a rescan `confirmDelay` later;
/// - switching to another folder parks the old folder's layout (`StateStore.switchRoot`) before the snapshot;
/// - the store's `LayoutSaver` debounces saves (1 s, at most 5 s behind).
///
/// Reading only: nothing here can change a user file.
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
        /// Overrides `FinderPrefs` for first-run gating (demo scripts).
        var finderHidesItems: Bool?
        /// Follow the mounted volumes for the drive hub (demos list their own, never the real ones).
        var watchesVolumes = true
    }

    let configuration: Configuration
    private unowned let store: Store
    private let stateStore: StateStore?
    private let engine = MirrorEngine()
    /// When a suspected mass removal was first seen (its confirming rescan is due).
    private var suspectSince: Date?
    private(set) var started = false
    /// Snapshots applied so far, and when the last one arrived (demo idle checks).
    private(set) var snapshotCount = 0
    private(set) var lastEventAt: Date?
    /// True from a connect or rescan request until its snapshot arrives.
    private(set) var awaitingScan = false
    // MARK: harden
    /// Called after each snapshot reaches the model, with how many have so far: the folder has been read, so the
    /// privacy prompt (if any) came from ⏻ (the session then looks for leftover copies).
    var onSnapshot: ((Int) -> Void)?

    init(configuration: Configuration, store: Store, stateStore: StateStore?) {
        self.configuration = configuration
        self.store = store
        self.stateStore = stateStore
        engine.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        engine.onVolumes = { [weak self] list in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.store.dispatch(.volumes(list)) }
            }
        }
    }

    /// Loads the saved layout into the store and, if already connected (or in a development mode), starts
    /// mirroring; otherwise shows the first-run card and waits for ⏻.
    func start() {
        guard !started else { return }
        started = true
        if let loaded = stateStore?.load() {
            for problem in loaded.problems { log("desk.json: \(problem)") }
            if let copy = loaded.corruptCopy { log("kept corrupt layout as \(copy.path)") }
            if let document = loaded.document { store.replace { $0 = document.makeState() } }
        }
        let state = store.state
        let rootMatches = state.root.map { $0.path == DesktopLocator.canonicalPath(configuration.folder) } ?? false
        if configuration.connectImmediately || (state.access == .connected && rootMatches) {
            store.replace { $0.access = .connecting }
            connect()
        } else {
            store.replace { $0.access = .notConnected }
            let hides = configuration.finderHidesItems ?? FinderPrefs.current().hidesDesktopItems
            if hides && configuration.settings.showDespiteFinderHidden != true { store.dispatch(.finderHidesItems) }
        }
        if configuration.watchesVolumes { engine.startVolumes() }
    }

    /// Starts watching, or rescans when the watcher already runs (`Effect.connectDesktop`, Choose Folder…).
    func connect() {
        awaitingScan = true
        engine.watch(configuration.folder)
    }

    /// Rescans now (wake, session active).
    func rescan() {
        awaitingScan = true
        engine.rescan(preservingContinuity: false)
    }

    func stop() {
        engine.stop()
    }

    // MARK: Events (main actor)

    private func handle(_ event: DesktopWatcher.Event) {
        lastEventAt = Date()
        switch event {
        case let .snapshot(snapshot):
            guard confirmed(snapshot) else { return }
            awaitingScan = false
            do {
                try store.replace { try stateStore?.switchRoot(&$0, to: snapshot.rootPath, now: snapshot.scannedAt) }
            } catch {
                log("could not keep the previous folder's layout: \(error)")
            }
            snapshotCount += 1
            store.dispatch(.snapshot(snapshot, now: snapshot.scannedAt))
            onSnapshot?(snapshotCount)
        case let .failed(.accessDenied(path)):
            awaitingScan = false
            log("no access to \(path)")
            store.dispatch(.accessDenied)
        case let .failed(failure):
            // A vanished folder (iCloud Desktop toggling, unmounted volume) keeps the layout; RootChanged rescans.
            awaitingScan = false
            log("scan failed: \(failure)")
        }
    }

    /// False while a scan that would remove most of the desk waits for a confirming rescan (a folder being
    /// replaced, an iCloud toggle); the rescan, or any scan after `confirmDelay`, is applied.
    private func confirmed(_ snapshot: DesktopSnapshot) -> Bool {
        guard Reconciler.isMassRemoval(store.state, snapshot) else {
            suspectSince = nil
            return true
        }
        let now = Date()
        if let since = suspectSince {
            if now.timeIntervalSince(since) >= configuration.confirmDelay {
                suspectSince = nil
                return true
            }
            return false
        }
        suspectSince = now
        log("a scan would remove most of the desk; confirming in \(configuration.confirmDelay) s")
        let continuous = snapshot.continuous
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.confirmDelay) { [weak self] in
            MainActor.assumeIsolated { self?.engine.rescan(preservingContinuity: continuous) }
        }
        return false
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("Deskterior mirror: \(message)\n".utf8))
    }

    // MARK: Launch configuration

    /// The folder, state and cache locations for `options`. Development modes must name a scratch folder
    /// (never the real desktop, inside it, or above it) and default to a temporary state directory so they
    /// cannot disturb the real layout. State and cache folders inside the mirrored folder are refused (they would
    /// show up as tokens, and every save would rescan into another save).
    ///
    /// Desk mode mirrors the folder chosen in Settings (`settings.mirroredFolder`) when no `--desktop-folder` is given,
    /// unless `useSavedFolder` is false (Settings is switching folders right now). `settings` are the launch's
    /// (`SettingsStore`: the app's in desk mode, throwaway ones otherwise); nothing here reads `UserDefaults`.
    /// `realDesktop` and `home` are the user's (tests pass stand-ins, so the refusal is checked without ever naming
    /// the real folder).
    static func configuration(
        options: LaunchOptions, environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleID: String = AppIdentity.bundleID, settings: DeskSettings = DeskSettings(), useSavedFolder: Bool = true,
        realDesktop: URL = DesktopLocator.defaultDesktopURL(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws(SafetyGuard.Refusal) -> Configuration {
        let mode: SafetyGuard.Mode = switch options.mode {
        case .desk: .desk
        case .windowed: .windowed
        case .headless: options.demo == nil ? .headless : .demo
        }
        let saved = useSavedFolder && mode == .desk ? settings.mirroredFolder : nil
        let resolution = DesktopLocator.resolve(override: options.desktopFolder ?? saved, environment: environment)
        let folder = try SafetyGuard.mirrorFolder(resolution, mode: mode, realDesktop: realDesktop, home: home)
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
        try SafetyGuard.checkOwnFolder(stateDir, desktop: realDesktop, mirrored: folder)
        try SafetyGuard.checkOwnFolder(cacheDir, desktop: realDesktop, mirrored: folder)
        return Configuration(
            folder: folder, stateDirectory: stateDir, iconCacheDirectory: cacheDir, connectImmediately: mode != .desk,
            settings: settings
        )
    }

    // MARK: harden

    /// The launch guard as a decision (DESIGN §3.7 item 7): the refusal that makes the app exit with code 64 before
    /// any window, mirror or file operator exists, or nil when `options` may start.
    static func launchRefusal(
        options: LaunchOptions, environment: [String: String], settings: DeskSettings = DeskSettings(),
        realDesktop: URL, home: URL
    ) -> SafetyGuard.Refusal? {
        do throws(SafetyGuard.Refusal) {
            _ = try configuration(options: options, environment: environment, bundleID: AppIdentity.fallbackBundleID,
                                  settings: settings, realDesktop: realDesktop, home: home)
            return nil
        } catch {
            return error
        }
    }

    /// `configuration(options:)`, or prints the refusal and exits with code 64 (DESIGN §3.7 item 7).
    static func configurationOrExit(options: LaunchOptions, settings: DeskSettings = DeskSettings()) -> Configuration {
        do throws(SafetyGuard.Refusal) {
            return try configuration(options: options, settings: settings)
        } catch {
            FileHandle.standardError.write(Data("Deskterior: \(error)\n".utf8))
            exit(error.exitCode)
        }
    }
}

/// The background half of `MirrorController`: the FSEvents watcher (with its scanner) and the volume watcher,
/// confined to one serial queue. It never touches the model; events go out through `onEvent` / `onVolumes`.
nonisolated final class MirrorEngine: @unchecked Sendable {
    /// Set once before use.
    var onEvent: @Sendable (DesktopWatcher.Event) -> Void = { _ in }
    var onVolumes: @Sendable ([VolumeEntry]) -> Void = { _ in }

    private let queue = DispatchQueue(label: "deskterior.mirror", qos: .userInitiated)
    // Confined to `queue`.
    private var watcher: DesktopWatcher?
    private var volumes: VolumeWatcher?

    /// Starts watching `folder` (with an initial scan), or rescans when already watching.
    func watch(_ folder: URL) {
        queue.async { [self] in
            if let watcher {
                watcher.rescanNow()
                return
            }
            let handler = onEvent
            let watcher = DesktopWatcher(scanner: DesktopScanner(root: folder)) { event in handler(event) }
            self.watcher = watcher
            watcher.start()
        }
    }

    func rescan(preservingContinuity: Bool) {
        queue.async { [self] in watcher?.rescanNow(preservingContinuity: preservingContinuity) }
    }

    func startVolumes() {
        queue.async { [self] in
            guard volumes == nil else { return }
            let handler = onVolumes
            let v = VolumeWatcher { list in handler(list) }
            volumes = v
            v.start()
        }
    }

    func stop() {
        queue.sync {
            watcher?.stop()
            watcher = nil
            volumes?.stop()
            volumes = nil
        }
    }
}
