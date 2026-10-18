import AppKit
import DeskCore
import DeskFiles
import DeskScene
import Metal

/// The app shell: desk (or `--windowed`) window, the `DeskSession` (store, mirror, effects, scene sync), status
/// item, context menus, Inventory, Memos and Arrange Desk, system observers, and the dev flags that act after launch
/// (`--print-window-id`, `--exit-after`). Headless runs and demos never get here (`runHeadless`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    private var displays: DisplayManager?
    private var statusMenu: StatusMenu?
    private var session: DeskSession?
    private var inventory: InventoryWindowController?
    // MARK: tidy and memos (0.3.0)
    private var memos: MemoWindowController?
    private var arrange: ArrangeDeskWindowController?
    private var resignKeyObserver: (any NSObjectProtocol)?
    private(set) var isUserPaused = false
    // MARK: system (M12)
    private var settingsStore: SettingsStore?
    private var integration: AppSystem?
    private var safeMode: SafeModeController?

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // MARK: system (M12): settings and the language first; Safe Mode (⌥ held, or --safe-mode) before the desk.
        let settings = SettingsStore.forLaunch(options)
        settingsStore = settings
        L10n.apply(settings.settings.language)
        installKeyRoutingMenu()
        if let seconds = options.exitAfter {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                NSApp.terminate(nil)
            }
        }
        if options.safeMode || NSEvent.modifierFlags.contains(.option) {
            let configuration = MirrorController.configurationOrExit(options: options, settings: settings.settings)
            let controller = SafeModeController(stateDirectory: configuration.stateDirectory, mirrored: configuration.folder) {
                [weak self] in self?.launchDesk()
            }
            safeMode = controller
            controller.show()
            Log.info("safe mode")
            WindowShots.schedule(options, windows: { [weak controller] in
                controller?.shownWindow.map { [("safe-mode", $0)] } ?? []
            })
            return
        }
        launchDesk()
    }

    /// Starts the desk: displays, the session, the status item, and the system integration.
    private func launchDesk() {
        guard let device = MTLCreateSystemDefaultDevice() else { Self.fail("no Metal device") }
        let configuration = MirrorController.configurationOrExit(
            options: options, settings: settingsStore?.settings ?? DeskSettings()
        )
        if let saved = configuration.savedFolderUnavailable {
            Log.info("mirrored folder not available, showing the Desktop this time: \(saved)")
        }

        let displays = DisplayManager(options: options, device: device)
        // M12: the desk display and walls follow the settings from the start.
        displays.settings = { [weak self] in self?.settingsStore?.settings ?? DeskSettings() }
        do {
            try displays.start()
        } catch {
            Self.fail("could not start the desk: \(error)")
        }
        self.displays = displays
        guard let host = displays.host else { Self.fail("no scene host") }
        Self.configure(host, options)
        host.scene.onRenderRequest = { [weak host] in host?.loop.renderOnce() }
        let session = DeskSession(host: host, options: options, configuration: configuration, dryRun: false)
        session.isPaused = { [weak self] in self?.isUserPaused ?? false }
        session.settings = settingsStore
        host.scene.onRequest = { [weak self] in self?.handle($0) }
        self.session = session
        session.attach(to: displays.view)  // MARK: files
        session.start()
        host.scene.startClock()
        host.loop.renderOnce()
        // A dev burst plays only in a window (never on the real desk's layout).
        if options.burst, options.windowed != nil {
            BurstDriver.start(host: host, store: session.store, endOnAV: options.burstAV)
        }

        statusMenu = StatusMenu(
            spec: { [weak self] in self?.statusSpec() ?? MenuSpec([]) },
            perform: { [weak self] in self?.perform($0) }
        )
        // MARK: system (M12)
        let integration = AppSystem(options: options, settings: settingsStore ?? SettingsStore.forLaunch(options),
                                    displays: displays, session: session)
        integration.perform = { [weak self] in self?.perform($0) }
        integration.isUserPaused = { [weak self] in self?.isUserPaused ?? false }
        integration.setUserPaused = { [weak self] in self?.setUserPaused($0) }
        integration.switchFolder = { [weak self] in self?.switchFolder($0) ?? false }
        integration.languageChanged = { [weak self] in
            self?.inventory?.languageChanged()
            self?.memos?.languageChanged()
            self?.arrange?.languageChanged()
        }
        self.integration = integration
        integration.start()
        if options.mode != .desk, options.show.contains("inventory") { showInventory() }
        if options.mode != .desk, options.show.contains("memos") { showMemos(.today) }
        if options.mode != .desk, options.show.contains("arrange") { showArrangeDesk() }
        WindowShots.schedule(options, windows: { [weak self, weak integration] in
            (integration?.shownWindows ?? []) + (self?.shownWindows ?? [])
        })
        if let window = displays.window {
            // A gesture whose mouse-up goes to another window or app must not stay in hand.
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak host] _ in
                MainActor.assumeIsolated { host?.cancelInput() }
            }
        }

        let mode = options.windowed.map { "windowed \($0)" } ?? "desk (level \(displays.level.rawValue))"
        Log.info("Deskterior \(DeskCore.version), \(mode), bundle id \(AppIdentity.bundleID)")
        if options.printWindowID, let window = displays.window {
            print(window.windowNumber)
            fflush(stdout)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        options.windowed != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        integration?.invalidate()
        memos?.flush()  // MARK: memos (0.3.0): what is being typed reaches the model, then memos.json.
        session?.stop()
        displays?.invalidate()
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
    }

    func applicationDidResignActive(_ notification: Notification) {
        session?.host.cancelInput()
    }

    func togglePause() {
        setUserPaused(!isUserPaused)
    }

    func setUserPaused(_ paused: Bool) {
        guard paused != isUserPaused else { return }
        isUserPaused = paused
        displays?.setUserPaused(paused)
        integration?.userPaused(paused)
        session?.sync.refreshMenuContext()
        Log.info(paused ? "desk paused" : "desk resumed")
    }

    // MARK: Commands

    private func statusSpec() -> MenuSpec {
        guard let session else { return MenuSpec([]) }
        let store = session.store
        return MenuSpec.status(store.state, MenuSpec.Context(paused: isUserPaused, undo: store.undoLabel, redo: store.redoLabel,
                                                             today: session.host.scene.today))
    }

    /// Runs a menu command: model commands go to the store (as picked from a menu, or `origin`), the rest are the
    /// app's.
    func perform(_ command: MenuCommand, from origin: ExplicitIntent.Origin = .menuItem) {
        integration?.userInput()  // M12: a frozen (on-battery) desk shows what the command does.
        // MARK: memos (0.3.0): Undo or Redo from the status menu (it never takes key) while the Memos window holds
        // typing: the typing is committed first, so the Undo takes it back, and the editors show what the step put
        // back (one being typed in never takes model text by itself).
        let undoing = command == .undo || command == .redo
        if undoing { memos?.flush() }
        defer { if undoing { memos?.reloadClean() } }
        if session?.perform(command, from: origin) == true { return }
        switch command {
        case .inventory:
            showInventory()
        case let .pauseDesk(paused):
            setUserPaused(paused)
        case .openDesktopFolder:
            if let folder = session?.configuration.folder { NSWorkspace.shared.open(folder) }
        case .about:
            integration?.showAbout()
        case .quit:
            NSApp.terminate(nil)
        case .peekDesk:
            integration?.togglePeek()
        case .settings:
            integration?.showSettings()
        // MARK: tidy and memos (0.3.0)
        case .newNote:
            newNote()
        case let .editNote(id):
            showMemos(.note(id))
        case let .openMemos(target):
            showMemos(target)
        case .arrangeDesk:
            showArrangeDesk()
        default:
            break
        }
    }

    private func handle(_ request: SceneRequest) {
        switch request {
        case let .menu(spec, at):
            guard let view = displays?.view else { return }
            let bridge = MenuBridge { [weak self] in self?.perform($0) }
            view.showMenu(bridge.menu(spec), atArt: at)
            withExtendedLifetime(bridge) {}
        case .inventory:
            showInventory()
        case let .command(command):
            perform(command)
        }
    }

    // MARK: system (M12)

    /// Settings ▸ Mirrored folder (desk mode): a new session on the same scene mirrors `path` (nil: the Desktop),
    /// connecting at once (the user chose it); the old folder's layout is parked by the mirror (Errata 11). False
    /// when the folder may not be mirrored.
    private func switchFolder(_ path: String?) -> Bool {
        guard let old = session else { return false }
        var o = options
        o.desktopFolder = path
        guard var configuration = try? MirrorController.configuration(
            options: o, settings: settingsStore?.settings ?? DeskSettings(), useSavedFolder: false
        ) else { return false }
        configuration.connectImmediately = true
        memos?.flush()  // MARK: memos (0.3.0): into the old session's store, which saves it as it stops.
        old.stop()
        let new = DeskSession(host: old.host, options: options, configuration: configuration, dryRun: false)
        new.isPaused = { [weak self] in self?.isUserPaused ?? false }
        new.settings = settingsStore
        session = new
        new.attach(to: displays?.view)
        inventory?.close()
        inventory = nil
        memos?.close()
        memos = nil
        arrange?.close()
        arrange = nil
        new.start()
        integration?.adopt(new)
        Log.info("mirroring \(configuration.folder.path)")
        return true
    }

    private func showInventory() {
        guard let session else { return }
        if inventory == nil {
            let controller = InventoryWindowController(store: session.store) { [weak self] in self?.perform($0, from: .inventory) }
            controller.monitorFrame = { [weak self] in self?.monitorScreenFrame() }
            controller.coveredPiles = { [weak self] in self?.session?.host.scene.matCoverage.coveredPiles ?? [] }  // MARK: mat
            // MARK: files
            controller.moveToTrash = { [weak self] keys in self?.session?.perform(.moveToTrash(keys), from: .inventory) }
            inventory = controller
        }
        inventory?.show()
    }

    /// The monitor's glass in screen coordinates (Show on Desk moves the Inventory off it).
    private func monitorScreenFrame() -> NSRect? {
        guard let layout = session?.host.scene.layout else { return nil }
        return screenRect(ofCanvas: layout.rect(CoreLayout.screen))
    }

    /// A canvas art rect of the desk in screen coordinates.
    private func screenRect(ofCanvas r: ArtRect) -> NSRect? {
        guard let view = displays?.view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.viewRect(fromArt: r), to: nil))
    }

    // MARK: tidy and memos (0.3.0)

    /// The app's own windows on show (development screenshots, `--window-shots`).
    private var shownWindows: [(name: String, window: NSWindow)] {
        var out: [(String, NSWindow)] = []
        if let w = inventory?.shownWindow { out.append(("inventory", w)) }
        if let w = memos?.shownWindow { out.append(("memos", w)) }
        if let w = arrange?.shownWindow { out.append(("arrange", w)) }
        return out
    }

    /// The Memos window of this session (made on first use).
    private func memoWindow() -> MemoWindowController? {
        guard let session else { return nil }
        if memos == nil {
            memos = MemoWindowController(store: session.store, today: { [weak self] in
                self?.session?.host.scene.today ?? DayKey(SceneClock.live.now())
            }, perform: { [weak self] in self?.perform($0) })
        }
        return memos
    }

    /// Memos… / Today's Memo… / Edit Note… / a click on a note, the pad or a calendar day: the window opens beside
    /// what it is about.
    private func showMemos(_ target: MemoTarget) {
        guard let memos = memoWindow() else { return }
        memos.show(target, near: memoTargetFrame(target), session: nil)
    }

    /// New Sticky Note from a menu: a yellow note on the first free spot, and its editor in the same editing session,
    /// so the note and the first words typed into it are one undo entry. Nothing opens when the partition is full (its
    /// toast says so).
    private func newNote() {
        guard let session, let memos = memoWindow() else { return }
        let store = session.store
        let id = store.state.memos.nextNoteID, editing = memos.nextSession()
        store.dispatch(.addNote(NewNote(id: id, text: "", colour: .yellow), session: editing))
        session.sync.refreshMenuContext()
        guard store.state.memos.notes[id] != nil else { return }
        memos.show(.note(id), near: memoTargetFrame(.note(id)), session: editing)
    }

    /// Where on the screen the desk shows what the Memos window opens on: the note, the day's cell on the wall
    /// calendar (else the calendar), the pad for today (else the calendar), the D-Day card.
    private func memoTargetFrame(_ target: MemoTarget) -> NSRect? {
        guard let session, let layout = session.host.scene.layout else { return nil }
        let scene = session.host.scene, state = session.store.state
        let art: ArtRect? = switch target {
        case let .note(id): scene.noteRect(id)
        case .today where state.isOut(.dailyPad): layout.anchors["partition.pad"]
        case .today: layout.anchors["calendar"]
        case let .day(d) where d.year == scene.today.year && d.month == scene.today.month:
            scene.calendarDayRect(d.day) ?? layout.anchors["calendar"]
        case .day: layout.anchors["calendar"]
        case .dDay where state.isOut(.dDayCard) && state.memos.dDay != nil: layout.anchors["partition.dday"]
        case .dDay, .notes: nil
        }
        return art.flatMap(screenRect(ofCanvas:))
    }

    private func showArrangeDesk() {
        guard let session else { return }
        if arrange == nil { arrange = ArrangeDeskWindowController(store: session.store) }
        arrange?.show()
    }

    /// An accessory app shows no menu bar (DESIGN Errata 1); this hidden main menu only routes key equivalents.
    private func installKeyRoutingMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = #selector(NSApplication.terminate(_:))
        appMenu.addItem(NSMenuItem(title: "Quit Deskterior", action: quit, keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Standard selectors, sent to the first responder: the desk view, or the Inventory's search field.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: #selector(DeskView.undo(_:)), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: #selector(DeskView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(DeskView.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(DeskView.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        // ⌘W closes the Inventory (the borderless desk window has no close button and stays).
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Deskterior: \(message)\n".utf8))
        exit(1)
    }
}

/// One desk's moving parts wired together (DESIGN §4.3): the `Store`, the `SceneSync` that shows it, the
/// `EffectRunner` that carries out its effects, the `MirrorController` that feeds it the folder, and the
/// `IconProvider` (unless `--icons kind`). The live app and the demo runner build the same session; a dry run
/// records file effects instead of running them.
final class DeskSession {
    let host: SceneHost
    let configuration: MirrorController.Configuration
    let store: Store
    let sync: SceneSync
    let effects: EffectRunner
    let mirror: MirrorController
    let icons: IconProvider?
    var isPaused: () -> Bool = { false } {
        didSet { sync.isPaused = isPaused }
    }
    /// M12: the launch's settings ("Show them on the desk anyway" is remembered there; nil in demos).
    var settings: SettingsStore?
    private let lights: LightsMode
    private let dryRun: Bool
    // MARK: files
    /// The file operator and its undo records (nil when the state folder cannot hold the operation log).
    let files: FileActions?
    let dropIn: DropInController
    let dragOut: DragOutController
    // MARK: harden
    /// Leftovers of an interrupted copy in the mirrored folder (Settings lists them; Errata 25).
    let leftovers: LeftoverCopies

    /// `fileRoots`: scratch folders a demo may drop from (outside desk mode the operator is confined to the mirrored
    /// folder, the state folder and these).
    init(host: SceneHost, options: LaunchOptions, configuration: MirrorController.Configuration, dryRun: Bool,
         lights: LightsMode? = nil, seed: UInt64? = nil, fileRoots: [URL] = []) {
        self.host = host
        self.configuration = configuration
        self.lights = lights ?? options.lights
        self.dryRun = dryRun
        let stateStore: StateStore?
        do {
            stateStore = try StateStore(directory: configuration.stateDirectory, mirrored: configuration.folder)
        } catch {
            FileHandle.standardError.write(Data("Deskterior: state store unavailable: \(error)\n".utf8))
            stateStore = nil
        }
        let saver = stateStore.map { LayoutSaver(store: $0, delay: configuration.persistDelay, maxWait: configuration.persistMaxWait) }
        // MARK: memos (0.3.0): memos.json beside desk.json, armed by the mirror once it was read (Erratum 31). When
        // the saves stop mid-session (the file turned newer or unreadable), a toast says so.
        let memoSaver = stateStore.map {
            MemoSaver(store: $0, delay: configuration.persistDelay, maxWait: configuration.persistMaxWait) { [weak host] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { host.map(Self.memosNotSaved) }
                }
            }
        }
        store = Store(saver: saver, memoSaver: memoSaver)
        store.seed = seed ?? options.seed ?? 0
        if options.icons == .live {
            let cache = try? IconCache(directory: configuration.iconCacheDirectory, mirrored: configuration.folder)
            icons = IconProvider(cache: cache)
        } else {
            icons = nil
        }
        sync = SceneSync(host: host, store: store, icons: icons)
        effects = EffectRunner(host: host, folder: configuration.folder, dryRun: dryRun)
        // MARK: files
        let mode: SafetyGuard.Mode = switch options.mode {
        case .desk: .desk
        case .windowed: .windowed
        case .headless: options.demo == nil ? .headless : .demo
        }
        let scope = FileActionScope(mode: mode, folder: configuration.folder,
                                    stateDirectory: configuration.stateDirectory, extraRoots: fileRoots)
        do {
            files = try FileActions(folder: configuration.folder, stateDirectory: configuration.stateDirectory, scope: scope)
        } catch {
            FileHandle.standardError.write(Data("Deskterior: file actions unavailable: \(error)\n".utf8))
            files = nil
        }
        effects.files = files
        dropIn = DropInController(host: host, store: store, effects: effects)
        dragOut = DragOutController(host: host, store: store, effects: effects)
        dragOut.alwaysCopy = configuration.settings.dragOutMode == .alwaysCopy  // "Drag-out: Always copy" (§3.6)
        mirror = MirrorController(configuration: configuration, store: store, stateStore: stateStore)
        leftovers = LeftoverCopies(folder: configuration.folder, host: host)  // MARK: harden
        effects.mirror = mirror
        effects.onAccessGranted = { [weak self] in
            self?.store.dispatch(.accessGranted)
            self?.mirror.connect()
        }
        store.effects = { [weak self] in self?.effects.run($0) }
        // MARK: files
        files?.dispatch = { [weak self] in self?.store.dispatch($0) }
        files?.showProgress = { [weak host] line in
            host?.scene.showProgress(line)
            host?.modelChanged()
        }
        store.willDispatch = { [weak self] action, state in
            // "Show them on the desk anyway" is remembered (DESIGN §4.8 showDespiteFinderHidden), in the launch's
            // settings: the app's in desk mode, memory in a development run.
            if case .requestConnect = action, state.access == .finderHidden, !dryRun {
                self?.settings?.update { $0.showDespiteFinderHidden = true }
            }
        }
        host.scene.onAction = { [weak self] action in
            guard let self else { return }
            // MARK: files: the scene's only file request is ⌘Z (its key or the hidden Edit menu's Undo).
            if case .undo = action { effects.withOrigin(.undo) { store.dispatch(action) } } else { store.dispatch(action) }
        }
    }

    func start() {
        store.observe { [weak self] new, old in
            guard let self, new.lights.mode != old.lights.mode else { return }
            host.scene.lightsMode = new.lights.mode
        }
        // MARK: harden: once the mirror has read the folder (never before ⏻ on a first run), look for leftover copies.
        mirror.onSnapshot = { [weak self] count in if count == 1 { self?.leftovers.look() } }
        // MARK: memos (0.3.0): memos.json found newer or unreadable: the notes typed this time are not saved.
        mirror.onMemosNotSaved = { [weak self] in self.map { Self.memosNotSaved($0.host) } }
        sync.start()
        mirror.start()
        host.scene.lightsMode = store.state.lights.mode
        guard lights != .auto, lights != store.state.lights.mode else { return }
        if dryRun {
            // A demo's lights are part of its (throwaway) desk, so its menus agree.
            let l = store.state.lights
            store.dispatch(.lights(LightsState(mode: lights, room: l.room, lamp: l.lamp)))
        } else {
            // `--lights` is for this run only: shown, never saved into the user's layout. A Lights menu pick wins.
            host.scene.lightsMode = lights
        }
    }

    /// Runs a model menu command; false for app commands.
    @discardableResult
    func perform(_ command: MenuCommand) -> Bool {
        guard let action = command.action(store.state) else { return false }
        store.dispatch(action)
        sync.refreshMenuContext()
        return true
    }

    // MARK: files

    /// Runs a model menu command as requested from `origin`: a menu item, the Inventory.
    @discardableResult
    func perform(_ command: MenuCommand, from origin: ExplicitIntent.Origin) -> Bool {
        var done = false
        effects.withOrigin(origin) { done = perform(command) }
        return done
    }

    /// Hands the desk view this session's drop-in and drag-out (at launch and after every folder switch): the old
    /// session's hold its store and effect runner unowned, and those go with it.
    func attach(to view: DeskView?) {
        view?.dragOut = dragOut
        view?.dropIn = dropIn
    }

    // MARK: harden

    /// Settings ▸ Leftover copies ▸ Move to Trash: the button is the gesture (a menu intent). `done` gets the line
    /// Settings shows afterwards (also when there was nothing left to trash, or nothing could run), and the folder is
    /// looked at again.
    func trashLeftovers(_ done: @escaping (String) -> Void) {
        let items = leftovers.found
        guard !items.isEmpty else {
            done(tr(.leftoversNone))
            return leftovers.look()
        }
        effects.withOrigin(.menuItem) {
            effects.trashLeftovers(items) { [weak self] result in
                guard let self else { return }
                let report = result.map { FileReport(trash: $0, keys: items.map(\.key), undo: nil) }
                done(report.map { $0.toast?.text ?? tr(.leftoversTrashed) } ?? ToastKey.fileFailed.text)
                leftovers.look()
            }
        }
    }

    // MARK: memos (0.3.0)

    /// Tells the user that memo changes are not saved this session (Erratum 31: `memos.json` is never written over
    /// when it is newer or unreadable).
    static func memosNotSaved(_ host: SceneHost) {
        host.scene.toast(.memosNotSaved)
        host.modelChanged()
    }

    /// Brings the scene to rest (a carry springs back; a drawer or the chair mid-motion commits where it is; whatever
    /// is in the air lands) so its end is saved, then saves and stops watching.
    func stop() {
        host.cancelInput()
        host.scene.forceRest()
        store.flush()
        mirror.stop()
    }
}

extension AppDelegate {
    /// Applies the scene flags (`--calibration`, `--clock`, `--lights`) and connects the lit pass.
    static func configure(_ host: SceneHost, _ options: LaunchOptions) {
        host.scene.setContent(options.calibration ? .calibration : .room)
        host.scene.clock = options.sceneClock
        host.scene.lightsMode = options.lights
        host.scene.reduceMotion = options.reduceMotion
        host.scene.connect(presenter: host.presenter)
    }

    /// The snapshot base name: `calibration`, or `room-<display>-<HHMM>[-<lights>]`.
    static func snapshotName(_ options: LaunchOptions, time: WallTime) -> String {
        if options.calibration { return "calibration" }
        let hhmm = String(format: "%02d%02d", time.hour, time.minute)
        let lights = options.lights == .auto ? "" : "-\(options.lights.rawValue)"
        return "room-\(options.emulatedDisplay)-\(hhmm)\(lights)"
    }

    /// `--headless`: steps `--frames` fixed frames offscreen on the emulated display and, with
    /// `--snapshot-dir`, writes `<name>.png` (art px) and `<name>@<N>x.png` (see `snapshotName`); with `--demo`,
    /// runs the script (`DemoRunner`). Returns the exit code.
    static func runHeadless(_ options: LaunchOptions) -> Int32 {
        if options.demo != nil { return DemoRunner.runBlocking(options) }
        // Plain --headless reads no folder; given one, it is held to the launch guard (exit 64) like the other modes.
        if options.desktopFolder != nil { _ = MirrorController.configurationOrExit(options: options) }
        let display = options.emulatedDisplay
        let grid = PixelGrid(display: display.geometry(), pixelSize: options.pixelSize)
        guard let device = MTLCreateSystemDefaultDevice() else {
            FileHandle.standardError.write(Data("Deskterior: no Metal device\n".utf8))
            return 1
        }
        do {
            let host = try SceneHost(grid: grid, device: device)
            configure(host, options)
            let driver = OffscreenDriver(host: host)
            driver.run(frames: options.frames)
            let frame = try driver.snapshot()
            print("headless \(display): S \(grid.scale), canvas \(grid.artSize), crop L\(grid.cropLeft) "
                + "T\(grid.cropTop) R\(grid.cropRight) B\(grid.cropBottom), core \(grid.coreRect), "
                + "frames \(options.frames)")
            if let dir = options.snapshotDir {
                let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
                let mirrored = options.desktopFolder.map {
                    URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
                }
                let writer = try ArtifactWriter(directory: url, mirrored: mirrored)
                let name = snapshotName(options, time: options.sceneClock.now())
                for png in Snapshotter.pngs(frame, name: name, scale: options.snapshotScale) {
                    print("wrote \(try writer.write(png.data, named: png.name).path)")
                }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Deskterior: headless run failed: \(error)\n".utf8))
            return 1
        }
    }
}
