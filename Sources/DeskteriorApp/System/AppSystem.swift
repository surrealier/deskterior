import AppKit
import DeskCore
import DeskFiles
import DeskScene

/// The desk's system integration (DESIGN §4.5–§4.11, §6; M12), wired once the desk is up: settings and the language,
/// the `SystemObservers` gate on the frame loop, Peek Desk and its opt-in hotkey, Launch at Login, the widget probe,
/// VoiceOver, the walls' drops and menus, Settings, About & Credits, the first-run welcome with the cover prompt, and
/// the App Translocation note.
///
/// Only desk mode reaches the system: development runs (`--windowed`) keep settings in memory and use recording
/// stand-ins for the hotkey and the login item, so nothing on this Mac changes.
final class AppSystem {
    let options: LaunchOptions
    let settings: SettingsStore
    let displays: DisplayManager
    private(set) var session: DeskSession
    let observers: SystemObservers
    let peek: PeekController
    private var hotKey = HotKeyPolicy()
    private let hotKeyRegistrar: any HotKeyRegistrar
    let loginItem: LoginItemController
    private var widgets: WidgetProbe?
    private var accessibility: DeskAccessibility?
    let reduceMotion: ReduceMotionObserver
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private let about = AboutWindowController()
    private let onboarding = OnboardingController()
    /// Runs a menu command (the app delegate's `perform`).
    var perform: (MenuCommand) -> Void = { _ in }
    /// Pause Desk is on (resumed before a peek).
    var isUserPaused: () -> Bool = { false }
    var setUserPaused: (Bool) -> Void = { _ in }
    /// Mirrors another folder (desk mode; nil: the Desktop); false when it may not be mirrored.
    var switchFolder: (String?) -> Bool = { _ in false }

    init(options: LaunchOptions, settings: SettingsStore, displays: DisplayManager, session: DeskSession) {
        self.options = options
        self.settings = settings
        self.displays = displays
        self.session = session
        let host = session.host
        observers = SystemObservers(loop: host.loop, pauseOnBattery: settings.settings.pauseOnBattery)
        peek = PeekController(displays: displays)
        let desk = options.mode == .desk
        loginItem = LoginItemController(service: desk ? MainAppLoginItem() : RecordingLoginItem())
        reduceMotion = ReduceMotionObserver(scene: host.scene, forced: options.reduceMotion) { [weak settings] in
            settings?.settings.reduceMotion ?? .followSystem
        }
        var onPress: () -> Void = {}
        hotKeyRegistrar = desk ? CarbonHotKeyRegistrar { onPress() } : RecordingHotKeyRegistrar()
        onPress = { [weak self] in self?.peek.toggle() }
    }

    func start() {
        let host = session.host
        observers.onCommand = { [weak self] in self?.run($0) }
        if let window = displays.window { observers.watchOcclusion(of: window) }
        peek.onChange = { [weak self] on in self?.observers.send(.peeking(on)) }
        peek.resumeIfPaused = { [weak self] in
            guard let self, self.isUserPaused() else { return }
            self.setUserPaused(false)
        }
        displays.settings = { [weak self] in self?.settings.settings ?? DeskSettings() }
        displays.wallState = { [weak host] in host?.scene.roomState }
        displays.onScreensChanged = { [weak self] in
            guard let self else { return }
            if let window = self.displays.window { self.observers.watchOcclusion(of: window) }
            self.widgets?.probe()
            self.peek.relayout()
        }
        displays.onWallDrop = { [weak self] urls, copy in self?.wallDrop(urls, copy: copy) }
        displays.onWallMenu = { [weak self] view, p in self?.wallMenu(view, at: p) }
        displays.settingsChanged()
        settings.observe { [weak self] new, old in self?.settingsChanged(new, old) }
        hotKey.apply(enabled: settings.settings.peekHotkeyEnabled, with: hotKeyRegistrar)
        loginItem.launchCheck(settings.settings) { [weak self] s, outcome in self?.loginOutcome(s, outcome) }
        if options.mode == .desk {
            let probe = WidgetProbe(host: host, displays: displays)
            widgets = probe
            probe.probe()
        }
        attachSession()
        firstRunNotes()
    }

    func invalidate() {
        peek.end()
        hotKey.apply(enabled: false, with: hotKeyRegistrar)
        observers.invalidate()
        widgets?.invalidate()
        accessibility?.invalidate()
        reduceMotion.invalidate()
    }

    /// A new session (another mirrored folder) took over the same scene.
    func adopt(_ new: DeskSession) {
        session = new
        accessibility?.invalidate()
        attachSession()
    }

    private func attachSession() {
        guard let view = displays.view else { return }
        accessibility = DeskAccessibility(view: view, store: session.store)
        // Toasts are pixels: VoiceOver hears them too (the effect still runs first).
        let inner = session.store.effects
        session.store.effects = { [weak self] effect in
            inner?(effect)
            if case let .toast(key) = effect { self?.accessibility?.announce(key) }
        }
        session.store.observe { [weak self] new, old in
            guard new.lights != old.lights else { return }
            self?.settingsModel?.lights = new.lights.mode
            self?.displays.renderWalls()
        }
    }

    // MARK: Commands

    func togglePeek() {
        peek.toggle()
    }

    /// Pause Desk was turned on or off.
    func userPaused(_ paused: Bool) {
        if paused { peek.end() }
        observers.send(.userPaused(paused))
    }

    private func run(_ command: SystemCommand) {
        let host = session.host
        switch command {
        case .forceRest:
            host.cancelInput()
            host.scene.forceRest()
        case .flush:
            session.store.flush()
        case .refreshDisplays:
            displays.settingsChanged()
        case .rescan:
            if session.store.state.access == .connected { session.mirror.rescan() }
        }
    }

    // MARK: Walls

    /// Files dropped on a wall go to the monitor, like a drop on its glass (DESIGN §4.10).
    private func wallDrop(_ urls: [URL], copy: Bool) {
        let s = session.store.state
        let cell = ScreenGrid.standard.firstFree(s.tokens.occupiedCells)
        session.store.dispatch(.importDropped(urls, at: cell.location, op: copy ? .copy : .move))
        session.host.modelChanged()
    }

    private func wallMenu(_ view: WallView, at p: NSPoint) {
        let spec = MenuSpec.desk(session.store.state, session.host.scene.menuContext)
        let bridge = MenuBridge { [weak self] in self?.perform($0) }
        bridge.menu(spec).popUp(positioning: nil, at: p, in: view)
        withExtendedLifetime(bridge) {}
    }

    // MARK: Settings

    func showSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(
                settings: settings.settings, lights: session.store.state.lights.mode,
                folderPath: session.configuration.folder.path, folderLocked: options.mode != .desk || options.desktopFolder != nil,
                displays: DisplayManager.displayNames()
            )
            model.actions = SettingsActions(
                setLights: { [weak self] mode in self?.perform(.lightsMode(mode)) },
                update: { [weak self] body in self?.settings.update(body) },
                setHotkey: { [weak self] on in self?.settings.update { $0.peekHotkeyEnabled = on } },
                setLaunchAtLogin: { [weak self] on in self?.setLaunchAtLogin(on) },
                chooseFolder: { [weak self] in self?.chooseFolder() },
                useDesktop: { [weak self] in self?.useFolder(nil) },
                showAbout: { [weak self] in self?.showAbout() }
            )
            settingsModel = model
            settingsWindow = AppWindow.make(title: tr(.settingsTitle), view: SettingsView(model: model))
        }
        settingsModel?.displays = DisplayManager.displayNames()
        loginItem.readStatus { [weak self] status in
            guard let self, self.settings.settings.launchAtLogin else { return }
            self.settingsModel?.loginStatus = status == .requiresApproval ? tr(.loginNeedsApproval) : nil
        }
        if let settingsWindow { AppWindow.present(settingsWindow) }
    }

    func showAbout() {
        about.show()
    }

    private func settingsChanged(_ new: DeskSettings, _ old: DeskSettings) {
        settingsModel?.settings = new
        if new.language != old.language {
            L10n.apply(new.language)
            settingsWindow?.title = tr(.settingsTitle)
            session.host.scene.apply(session.store.state)
            session.host.modelChanged()
        }
        if new.peekHotkeyEnabled != old.peekHotkeyEnabled {
            let on = hotKey.apply(enabled: new.peekHotkeyEnabled, with: hotKeyRegistrar)
            Log.info("hotkey ⌃⌥⌘D: \(on ? "registered" : "off")")
        }
        if new.pauseOnBattery != old.pauseOnBattery { observers.setPauseOnBattery(new.pauseOnBattery) }
        if new.reduceMotion != old.reduceMotion { reduceMotion.refresh() }
        if new.deskDisplayUUID != old.deskDisplayUUID || new.coverOtherDisplays != old.coverOtherDisplays {
            displays.settingsChanged()
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        settings.update { $0.launchAtLogin = on }
        loginItem.set(on, settings.settings) { [weak self] s, outcome in self?.loginOutcome(s, outcome) }
    }

    private func loginOutcome(_ s: DeskSettings, _ outcome: LoginItemOutcome) {
        settings.update {
            $0.launchAtLogin = s.launchAtLogin
            $0.loginItemVersion = s.loginItemVersion
        }
        let line: String? = switch outcome {
        case .added: tr(.loginAdded)
        case .removed: tr(.loginRemoved)
        case .needsApproval: tr(.loginNeedsApproval)
        case .failed: tr(.loginFailed)
        case .unchanged, .turnedOffElsewhere: nil
        }
        settingsModel?.loginStatus = line
        Log.info("login item: \(outcome)")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.configuration.folder
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useFolder(url.path)
    }

    private func useFolder(_ path: String?) {
        guard options.mode == .desk, options.desktopFolder == nil else { return }
        if switchFolder(path) {
            settings.update { $0.mirroredFolder = path }
            settingsModel?.folderPath = session.configuration.folder.path
            settingsModel?.folderNote = nil
        } else {
            settingsModel?.folderNote = tr(.folderUnavailable)
        }
    }

    // MARK: First run

    /// The welcome card (first desk run; it asks to cover other displays when there are several) and the
    /// App Translocation note; `--show onboarding,translocation` shows them in a development window.
    private func firstRunNotes() {
        let s = settings.settings
        let screens = NSScreen.screens.count
        let showWelcome = options.mode == .desk ? s.onboardingStep == 0 : options.show.contains("onboarding")
        if showWelcome {
            let ask = DisplayPlan.needsCoverPrompt(screenCount: screens, coverOthers: s.coverOtherDisplays)
                || (options.mode != .desk && options.show.contains("onboarding"))
            onboarding.showWelcome(askCover: ask) { [weak self] cover in
                self?.settings.update {
                    $0.onboardingStep = max($0.onboardingStep, 1)
                    if let cover { $0.coverOtherDisplays = cover }
                }
            }
        }
        let bundlePath = Bundle.main.bundlePath
        let translocated = options.mode == .desk ? Translocation.shouldShowNote(bundlePath: bundlePath, settings: s)
            : options.show.contains("translocation")
        if translocated {
            onboarding.showTranslocationNote { [weak self] in self?.settings.update { $0.translocationNoteShown = true } }
        }
        if options.mode != .desk {
            if options.show.contains("settings") { showSettings() }
            if options.show.contains("about") { showAbout() }
            if options.show.contains("peek") { peek.begin() }
        }
    }

    /// The app's windows on show (development screenshots, `--window-shots`).
    var shownWindows: [(name: String, window: NSWindow)] {
        var out: [(String, NSWindow)] = []
        if let w = settingsWindow, w.isVisible { out.append(("settings", w)) }
        if let w = about.shownWindow { out.append(("about", w)) }
        out += onboarding.shownWindows
        return out
    }
}
