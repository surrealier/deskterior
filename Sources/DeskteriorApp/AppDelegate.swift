import AppKit
import DeskCore
import DeskFiles
import DeskScene
import Metal

/// The app shell: desk (or `--windowed`) window, the `DeskSession` (store, mirror, effects, scene sync), status
/// item, context menus, Inventory, system observers, and the dev flags that act after launch
/// (`--print-window-id`, `--exit-after`). Headless runs and demos never get here (`runHeadless`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    private var displays: DisplayManager?
    private var statusMenu: StatusMenu?
    private var observers: SystemObservers?
    private var session: DeskSession?
    private var inventory: InventoryWindowController?
    private var resignKeyObserver: (any NSObjectProtocol)?
    private(set) var isUserPaused = false

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else { Self.fail("no Metal device") }
        installKeyRoutingMenu()
        let configuration = MirrorController.configurationOrExit(options: options)

        let displays = DisplayManager(options: options, device: device)
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
        host.scene.onRequest = { [weak self] in self?.handle($0) }
        self.session = session
        session.start()
        host.scene.startClock()
        host.loop.renderOnce()

        statusMenu = StatusMenu(
            spec: { [weak self] in self?.statusSpec() ?? MenuSpec([]) },
            perform: { [weak self] in self?.perform($0) }
        )
        if let window = displays.window {
            observers = SystemObservers(window: window, loop: host.loop) { [weak displays, weak session] in
                displays?.refreshGrid()
                session?.mirror.rescan()
            }
            // A gesture whose mouse-up goes to another window or app must not stay in hand.
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak host] _ in
                MainActor.assumeIsolated { host?.cancelInput() }
            }
        }

        let mode = options.windowed.map { "windowed \($0)" } ?? "desk (level \(options.level.rawValue))"
        Log.info("Deskterior \(DeskCore.version), \(mode), bundle id \(AppIdentity.bundleID)")
        if options.printWindowID, let window = displays.window {
            print(window.windowNumber)
            fflush(stdout)
        }
        if let seconds = options.exitAfter {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        options.windowed != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.stop()
        observers?.invalidate()
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
        session?.sync.refreshMenuContext()
        Log.info(paused ? "desk paused" : "desk resumed")
    }

    // MARK: Commands

    private func statusSpec() -> MenuSpec {
        guard let session else { return MenuSpec([]) }
        let store = session.store
        return MenuSpec.status(store.state, MenuSpec.Context(paused: isUserPaused, undo: store.undoLabel, redo: store.redoLabel))
    }

    /// Runs a menu command: model commands go to the store, the rest are the app's.
    func perform(_ command: MenuCommand) {
        if session?.perform(command) == true { return }
        switch command {
        case .inventory:
            showInventory()
        case let .pauseDesk(paused):
            setUserPaused(paused)
        case .openDesktopFolder:
            if let folder = session?.configuration.folder { NSWorkspace.shared.open(folder) }
        case .about:
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        case .quit:
            NSApp.terminate(nil)
        case .peekDesk, .settings:
            // TODO(M12): Peek Desk and the Settings window.
            session?.host.scene.toast(.notYetAvailable)
            session?.host.modelChanged()
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

    private func showInventory() {
        guard let session else { return }
        if inventory == nil {
            let controller = InventoryWindowController(store: session.store) { [weak self] in self?.perform($0) }
            controller.monitorFrame = { [weak self] in self?.monitorScreenFrame() }
            inventory = controller
        }
        inventory?.show()
    }

    /// The monitor's glass in screen coordinates (Show on Desk moves the Inventory off it).
    private func monitorScreenFrame() -> NSRect? {
        guard let view = displays?.view, let window = view.window, let layout = session?.host.scene.layout else { return nil }
        let glass = layout.rect(CoreLayout.screen)
        let a = view.viewPoint(fromArt: SIMD2(Float(glass.minX), Float(glass.minY)))
        let b = view.viewPoint(fromArt: SIMD2(Float(glass.maxX), Float(glass.maxY)))
        let local = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        return window.convertToScreen(view.convert(local, to: nil))
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
    private let lights: LightsMode
    private let dryRun: Bool

    init(host: SceneHost, options: LaunchOptions, configuration: MirrorController.Configuration, dryRun: Bool,
         lights: LightsMode? = nil, seed: UInt64? = nil) {
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
        store = Store(saver: saver)
        store.seed = seed ?? options.seed ?? 0
        if options.icons == .live {
            let cache = try? IconCache(directory: configuration.iconCacheDirectory, mirrored: configuration.folder)
            icons = IconProvider(cache: cache)
        } else {
            icons = nil
        }
        sync = SceneSync(host: host, store: store, icons: icons)
        effects = EffectRunner(host: host, folder: configuration.folder, dryRun: dryRun)
        mirror = MirrorController(configuration: configuration, store: store, stateStore: stateStore)
        effects.mirror = mirror
        effects.onAccessGranted = { [weak self] in
            self?.store.dispatch(.accessGranted)
            self?.mirror.connect()
        }
        let bundleID = AppIdentity.bundleID
        store.effects = { [weak self] in self?.effects.run($0) }
        store.willDispatch = { action, state in
            // "Show them on the desk anyway" is remembered (DESIGN §4.8 showDespiteFinderHidden).
            if case .requestConnect = action, state.access == .finderHidden, !dryRun {
                UserDefaults(suiteName: bundleID)?.set(true, forKey: DeskSettings.Key.showDespiteFinderHidden.rawValue)
            }
        }
        host.scene.onAction = { [weak self] in self?.store.dispatch($0) }
    }

    func start() {
        store.observe { [weak self] new, old in
            guard let self, new.lights.mode != old.lights.mode else { return }
            host.scene.lightsMode = new.lights.mode
        }
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

    /// Saves and stops watching.
    func stop() {
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
