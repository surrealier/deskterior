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
    /// Settings ▸ Language changed (the Find Item window follows).
    var languageChanged: () -> Void = {}
    /// Ends the user's spell of using a desk frozen on battery (`userInput`).
    private var inputSpell: Timer?
    /// The last try to register ⌃⌥⌘D failed (another app holds it); Settings says so.
    private var hotkeyTaken = false
    /// How long after the last click, key or menu command a desk frozen on battery stays live.
    static let inputSpellSeconds: TimeInterval = 30
    /// Walls take file drags: a drop on one goes to the monitor through the desk's drop-in (M11; DESIGN §4.10).
    static let wallsImportFiles = true

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
        // Every toast is pixels: VoiceOver hears them too, whoever raised them.
        host.scene.onToastShown = { [weak self] in self?.accessibility?.announce($0) }
        displays.view?.onInput = { [weak self] in self?.userInput() }
        displays.wallsAcceptFiles = Self.wallsImportFiles
        host.scene.matFlat = settings.settings.matMode == .flat  // the desk mat's Cloth/Flat (M9)
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
        displays.onWallDrop = { [weak self] urls, copy, keys in self?.wallDrop(urls, copy: copy, keys: keys) }
        displays.wallOperation = { [weak self] urls, copy, drag, keys in
            self?.session.dropIn.wallOperation(urls, copy: copy, drag: drag, keys: keys) ?? []
        }
        displays.onWallMenu = { [weak self] view, p in self?.wallMenu(view, at: p) }
        displays.settingsChanged()
        settings.observe { [weak self] new, old in self?.settingsChanged(new, old) }
        applyHotKey()
        loginItem.launchCheck(settings.settings, translocated: isTranslocated) { [weak self] s, outcome in
            self?.loginOutcome(s, outcome)
        }
        if options.mode == .desk {
            let probe = WidgetProbe(host: host, displays: displays)
            widgets = probe
            probe.probe()
        }
        attachSession()
        firstRunNotes()
    }

    func invalidate() {
        inputSpell?.invalidate()
        inputSpell = nil
        peek.end()
        hotKey.apply(enabled: false, with: hotKeyRegistrar)
        observers.invalidate()
        widgets?.invalidate()
        accessibility?.invalidate()
        reduceMotion.invalidate()
    }

    /// A new session (another mirrored folder) took over the same scene.
    func adopt(_ new: DeskSession) {
        session.leftovers.onChange = nil  // MARK: harden: the old folder's look no longer speaks for Settings.
        session = new
        accessibility?.invalidate()
        attachSession()
    }

    private func attachSession() {
        // MARK: harden: Settings follows the leftovers the session finds (none yet for a new folder, and no old note).
        session.leftovers.onChange = { [weak self] list in self?.settingsModel?.leftovers = list.count }
        settingsModel?.follow(session.leftovers)
        guard let view = displays.view else { return }
        accessibility = DeskAccessibility(view: view, store: session.store)
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

    /// The user clicked, typed or picked a menu command. A desk frozen on battery comes alive first, so what they do
    /// shows, and freezes again `inputSpellSeconds` after the last of it; otherwise nothing happens (no timer).
    func userInput() {
        guard observers.gate.freezesOnBattery else { return }
        if !observers.gate.conditions.interacting { observers.send(.interacting(true)) }
        inputSpell?.invalidate()
        let t = Timer(timeInterval: Self.inputSpellSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.inputSpell = nil
                self?.observers.send(.interacting(false))
            }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        inputSpell = t
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
    private func wallDrop(_ urls: [URL], copy: Bool, keys: DropKeys) {
        session.dropIn.dropOnWall(urls, copy: copy, keys: keys)
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
                showAbout: { [weak self] in self?.showAbout() },
                showLeftovers: { [weak self] in self?.session.leftovers.showInFinder() },
                trashLeftovers: { [weak self] in
                    self?.session.trashLeftovers { note in self?.settingsModel?.leftoverNote = note }
                }
            )
            model.pixelSizeLocked = options.pixelSizeGiven
            model.loginLocked = isTranslocated
            model.hotkeyStatus = hotkeyTaken ? tr(.hotkeyTaken) : nil
            // The saved folder was not there at launch: the desk shows the Desktop and the setting is kept.
            if session.configuration.savedFolderUnavailable != nil { model.folderNote = tr(.folderMissing) }
            settingsModel = model
            settingsWindow = AppWindow.make(title: tr(.settingsTitle), view: SettingsView(model: model))
        }
        settingsModel?.displays = DisplayManager.displayNames()
        settingsModel?.leftovers = session.leftovers.found.count  // MARK: harden
        // The toggle shows what is registered (an item added or removed outside the app, or a lost setting).
        loginItem.readStatus { [weak self] status in
            guard let self else { return }
            var s = self.settings.settings
            if LoginItemPolicy.reconcile(&s, status: status, version: self.loginItem.version) {
                Log.info("login item: the setting follows the status (\(status))")
                self.settings.update {
                    $0.launchAtLogin = s.launchAtLogin
                    $0.loginItemVersion = s.loginItemVersion
                }
            }
            self.settingsModel?.loginStatus = self.isTranslocated ? tr(.loginTranslocated)
                : (status == .requiresApproval ? tr(.loginNeedsApproval) : nil)
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
            settingsModel?.hotkeyStatus = hotkeyTaken ? tr(.hotkeyTaken) : nil
            session.host.scene.apply(session.store.state)
            session.host.modelChanged()
            languageChanged()
        }
        if new.peekHotkeyEnabled != old.peekHotkeyEnabled { applyHotKey() }
        if new.pixelSize != old.pixelSize { displays.settingsChanged() }
        if new.pauseOnBattery != old.pauseOnBattery { observers.setPauseOnBattery(new.pauseOnBattery) }
        if new.reduceMotion != old.reduceMotion { reduceMotion.refresh() }
        if new.matMode != old.matMode { session.host.scene.matFlat = new.matMode == .flat }
        if new.dragOutMode != old.dragOutMode { session.dragOut.alwaysCopy = new.dragOutMode == .alwaysCopy }
        if new.deskDisplayUUID != old.deskDisplayUUID || new.coverOtherDisplays != old.coverOtherDisplays {
            displays.settingsChanged()
        }
    }

    /// Registers or drops ⌃⌥⌘D to match the setting. When another app holds the combination the setting turns off
    /// and Settings says why, so the toggle never shows a shortcut that does nothing.
    private func applyHotKey() {
        let wanted = settings.settings.peekHotkeyEnabled, was = hotKey.registered
        let on = hotKey.apply(enabled: wanted, with: hotKeyRegistrar)
        if on != was || wanted {
            Log.info("hotkey ⌃⌥⌘D: \(on ? "registered" : (wanted ? "taken by another app" : "off"))")
        }
        if wanted, !on {
            hotkeyTaken = true
            settingsModel?.hotkeyStatus = tr(.hotkeyTaken)
            settings.update { $0.peekHotkeyEnabled = false }
        } else if on {
            hotkeyTaken = false
            settingsModel?.hotkeyStatus = nil
        }
    }

    /// Running from a translocated copy (a login item would record its temporary path).
    private var isTranslocated: Bool {
        guard options.mode == .desk else { return options.show.contains("translocation") }
        return Translocation.isTranslocated(bundlePath: Bundle.main.bundlePath)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        guard !isTranslocated || !on else {
            settingsModel?.loginStatus = tr(.loginTranslocated)
            return
        }
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
