import AppKit
import DeskCore
import DeskScene
import Metal

/// Owns the desk window, its view and its `SceneHost`, and the walls on the other displays (DESIGN §4.10), and keeps
/// them in step with the screens: screen-parameter changes (debounced 0.5 s), backing changes, and window resizes in
/// `--windowed` mode.
///
/// Desk mode puts the desk on the display chosen in Settings while it is connected, else on the menu-bar display
/// (`DisplayPlan`); with "Cover other displays" every other display gets a static `WallController`. When displays
/// come and go the plan is made again: the desk moves (its grid follows), walls are added, resized or closed.
/// `--windowed` emulates one display of the window's content size at the requested scale and shows no walls.
final class DisplayManager {
    let options: LaunchOptions
    let device: any MTLDevice
    private(set) var window: NSWindow?
    private(set) var view: DeskView?
    private(set) var host: SceneHost?
    /// The settings the plan reads (desk display, cover other displays, pixel size, and the window level in desk mode).
    var settings: () -> DeskSettings = { DeskSettings() }
    /// The room state walls are lit for (the desk scene's time and lights).
    var wallState: () -> RoomState? = { nil }
    /// Called after the desk moved to another display or the screens changed (re-probe widgets, re-watch occlusion).
    var onScreensChanged: (() -> Void)?
    /// Wall drops and right-clicks.
    var onWallDrop: (([URL], Bool) -> Void)?
    var onWallMenu: ((WallView, NSPoint) -> Void)?
    /// Walls take file drags (only once dropped files are imported; until then a drag over a wall is refused).
    var wallsAcceptFiles = false {
        didSet { for w in walls.values { w.view.acceptsFiles = wallsAcceptFiles } }
    }

    private(set) var plan = DisplayPlan(desk: nil, walls: [])
    private var planScreens: [DisplayInfo] = []
    private(set) var walls: [UInt32: WallController] = [:]
    private var screenObserver: (any NSObjectProtocol)?
    private var pendingScreenChange: Task<Void, Never>?
    private var wallTimer: Timer?
    private var paused = false
    private(set) var isPeeking = false

    init(options: LaunchOptions, device: any MTLDevice) {
        self.options = options
        self.device = device
    }

    /// Creates and shows the window (and walls), then wakes the loop once.
    func start() throws {
        let window: NSWindow
        if let emulated = options.windowed {
            let size = NSSize(width: emulated.widthPt, height: emulated.heightPt)
            window = WindowedDeskWindow(contentSize: size)
            if let visible = NSScreen.main?.visibleFrame {
                window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 24, y: visible.maxY))
            }
        } else {
            let screens = Self.displays()
            let s = settings()
            plan = DisplayPlan.make(screens, deskUUID: s.deskDisplayUUID, coverOthers: s.coverOtherDisplays)
            planScreens = screens
            guard let desk = screens.first(where: { $0.id == plan.desk }) else {
                throw RenderError.resource("the desk window (no screen)")
            }
            window = DeskWindow(frame: desk.frame.cg, level: level)
        }
        window.setAccessibilityLabel(tr(.axDesk))

        let content = window.contentRect(forFrameRect: window.frame)
        let view = DeskView(frame: NSRect(origin: .zero, size: content.size), device: device)
        view.emulatedScale = options.windowed?.scale
        let host = try SceneHost(grid: grid(for: view, scale: view.deviceScale), device: device)
        view.host = host
        window.contentView = view
        host.attach(to: view, layer: view.metalLayer)
        self.window = window
        self.view = view
        self.host = host
        view.onGeometryChange = { [weak self] in self?.refreshGrid() }

        show()
        window.makeFirstResponder(view)
        view.syncDrawable()
        refreshGrid(log: true)
        host.loop.wake()
        syncWalls()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// Stops observing, closes the walls and drops the display link.
    func invalidate() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        pendingScreenChange?.cancel()
        wallTimer?.invalidate()
        wallTimer = nil
        for w in walls.values { w.close() }
        walls.removeAll()
        host?.invalidate()
    }

    /// Pause Desk: orders the windows out and pauses the loop (a carry in hand springs back); resuming shows them and
    /// renders once.
    func setUserPaused(_ paused: Bool) {
        guard let host else { return }
        self.paused = paused
        if paused {
            host.scene.cancelInput()
            host.loop.setPaused(.userPaused, true)
            window?.orderOut(nil)
            for w in walls.values { w.hide() }
        } else {
            show()
            for w in walls.values { w.show() }
            host.loop.setPaused(.userPaused, false)
        }
    }

    /// Peek Desk: the desk window floats above other apps' windows (and is made key); leaving puts it back at the
    /// desktop level without making it key.
    func setPeeking(_ on: Bool) {
        guard let window, on != isPeeking else { return }
        isPeeking = on
        if options.windowed != nil {
            if on { NSApp.activate(); window.makeKeyAndOrderFront(nil) }
            return
        }
        if on {
            window.level = .floating
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.level = DeskWindow.windowLevel(level)
            if !paused { window.orderFrontRegardless() }
        }
    }

    /// Recomputes the grid from the current display and hands it to the host (re-renders once).
    func refreshGrid(log: Bool = false) {
        guard let view, let host else { return }
        let old = host.grid
        let new = grid(for: view, scale: view.deviceScale)
        do {
            try host.setGrid(new)
        } catch {
            Log.info("grid change failed: \(error)")
            return
        }
        if log || new != old {
            Log.info("grid S \(new.scale), canvas \(new.artSize), crop L\(new.cropLeft) T\(new.cropTop) "
                + "R\(new.cropRight) B\(new.cropBottom), core \(new.coreRect)")
        }
    }

    /// The desk display's geometry (desk mode), or nil.
    var deskDisplay: DisplayInfo? { planScreens.first { $0.id == plan.desk } }

    /// The pixel size (§4.8 chunky, normal, fine): `--pixel-size` for this run, else Settings ▸ Pixel size.
    var pixelSize: PixelSize { options.pixelSizeGiven ? options.pixelSize : settings().pixelSize }

    /// The desk's and walls' window level: `--level` for this run, else the hidden `windowLevel` setting (icon+1, or the
    /// S1 fallback icon+3); read when the windows are made.
    var level: LaunchOptions.Level {
        if options.levelGiven { return options.level }
        return settings().windowLevel == .iconPlus3 ? .iconPlus3 : .iconPlus1
    }

    /// Settings changed the desk display or the walls: plan again now.
    func settingsChanged() {
        applyScreenChange()
    }

    /// Re-lights the walls (the desk's lights or the hour changed).
    func renderWalls() {
        guard let state = wallState() else { return }
        for w in walls.values { w.render(state) }
    }

    // MARK: Screens

    /// Every connected display, the menu-bar display first.
    static func displays() -> [DisplayInfo] {
        NSScreen.screens.enumerated().map { i, s in info(s, hasMenuBar: i == 0) }
    }

    static func info(_ s: NSScreen, hasMenuBar: Bool) -> DisplayInfo {
        let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        var uuid: String?
        if let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, ref) as String?
        }
        return DisplayInfo(id: id, uuid: uuid, frame: PointRect(s.frame), visibleFrame: PointRect(s.visibleFrame),
                           backingScale: Double(s.backingScaleFactor), hasMenuBar: hasMenuBar)
    }

    /// Display names for Settings ▸ Desk display, by UUID.
    static func displayNames() -> [(uuid: String, name: String)] {
        NSScreen.screens.enumerated().compactMap { i, s in
            guard let uuid = info(s, hasMenuBar: i == 0).uuid else { return nil }
            return (uuid, s.localizedName)
        }
    }

    /// The display geometry the desk covers: the menu-bar screen, or the emulated display.
    static func geometry(of screen: NSScreen) -> DisplayGeometry {
        info(screen, hasMenuBar: false).geometry
    }

    private func grid(for view: DeskView, scale: Double) -> PixelGrid {
        let display: DisplayGeometry
        if let emulated = options.windowed {
            display = emulated.geometry(widthPt: view.bounds.width, heightPt: view.bounds.height)
        } else if let desk = deskDisplay {
            display = desk.geometry
        } else {
            display = DisplayGeometry(widthPt: view.bounds.width, heightPt: view.bounds.height, backingScale: scale)
        }
        return PixelGrid(display: display, pixelSize: pixelSize)
    }

    private func show() {
        guard let window else { return }
        if options.windowed != nil {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    private func screensChanged() {
        pendingScreenChange?.cancel()
        pendingScreenChange = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.applyScreenChange()
        }
    }

    private func applyScreenChange() {
        if options.windowed == nil, let window {
            let screens = Self.displays()
            let s = settings()
            let new = DisplayPlan.make(screens, deskUUID: s.deskDisplayUUID, coverOthers: s.coverOtherDisplays)
            let change = DisplayChange.between(old: plan, oldScreens: planScreens, new: new, screens: screens)
            plan = new
            planScreens = screens
            if let desk = deskDisplay, window.frame != desk.frame.cg {
                if change.moveDesk != nil { Log.info("desk moves to display \(desk.id)") }
                host?.cancelInput()
                window.setFrame(desk.frame.cg, display: false)
            }
            if !change.isEmpty { Log.info("displays: \(change)") }
        }
        view?.syncDrawable()
        refreshGrid()
        syncWalls()
        onScreensChanged?()
    }

    /// Opens, updates and closes walls to match the plan (desk mode only).
    private func syncWalls() {
        guard options.windowed == nil else { return }
        let wanted = Set(plan.walls)
        for (id, w) in walls where !wanted.contains(id) {
            w.close()
            walls[id] = nil
        }
        for id in plan.walls {
            guard let display = planScreens.first(where: { $0.id == id }) else { continue }
            if let w = walls[id] {
                w.update(display: display, pixelSize: pixelSize)
            } else {
                let w = WallController(display: display, level: level, pixelSize: pixelSize)
                w.view.acceptsFiles = wallsAcceptFiles
                w.view.onDrop = { [weak self] urls, copy in self?.onWallDrop?(urls, copy) }
                w.view.onMenu = { [weak self, weak w] p in
                    guard let self, let view = w?.view else { return }
                    self.onWallMenu?(view, p)
                }
                walls[id] = w
                if !paused { w.show() }
            }
        }
        renderWalls()
        // The light changes slowly: a look every 10 minutes is plenty, and only while there are walls.
        if walls.isEmpty {
            wallTimer?.invalidate()
            wallTimer = nil
        } else if wallTimer == nil {
            let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.renderWalls() }
            }
            t.tolerance = 60
            RunLoop.main.add(t, forMode: .common)
            wallTimer = t
        }
    }
}

extension PointRect {
    init(_ r: CGRect) {
        self.init(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height)
    }

    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
