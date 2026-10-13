import AppKit
import DeskCore
import DeskScene
import Metal

/// Owns the desk window, its view and its `SceneHost` (one display in M2; DESIGN §4.10) and keeps the
/// `PixelGrid` in step with the display: screen-parameter changes (debounced 0.5 s), backing changes, and
/// window resizes in `--windowed` mode.
///
/// Desk mode covers the menu-bar screen (`NSScreen.screens.first`); `--windowed` emulates a display of the
/// window's content size at the requested scale.
final class DisplayManager {
    let options: LaunchOptions
    let device: any MTLDevice
    private(set) var window: NSWindow?
    private(set) var view: DeskView?
    private(set) var host: SceneHost?

    private var screenObserver: (any NSObjectProtocol)?
    private var pendingScreenChange: Task<Void, Never>?

    init(options: LaunchOptions, device: any MTLDevice) {
        self.options = options
        self.device = device
    }

    /// Creates and shows the window, then wakes the loop once.
    func start() throws {
        let window: NSWindow
        if let emulated = options.windowed {
            let size = NSSize(width: emulated.widthPt, height: emulated.heightPt)
            window = WindowedDeskWindow(contentSize: size)
            if let visible = NSScreen.main?.visibleFrame {
                window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 24, y: visible.maxY))
            }
        } else {
            guard let screen = NSScreen.screens.first else { throw RenderError.resource("the desk window (no screen)") }
            window = DeskWindow(frame: screen.frame, level: options.level)
        }

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

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// Stops observing and drops the display link.
    func invalidate() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        pendingScreenChange?.cancel()
        host?.invalidate()
    }

    /// Pause Desk: orders the window out and pauses the loop (a carry in hand springs back); resuming shows it and
    /// renders once.
    func setUserPaused(_ paused: Bool) {
        guard let host else { return }
        if paused {
            host.scene.cancelInput()
            host.loop.setPaused(.userPaused, true)
            window?.orderOut(nil)
        } else {
            show()
            host.loop.setPaused(.userPaused, false)
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

    /// The display geometry the desk covers: the menu-bar screen, or the emulated display.
    static func geometry(of screen: NSScreen) -> DisplayGeometry {
        let f = screen.frame, v = screen.visibleFrame
        return DisplayGeometry(
            widthPt: f.width, heightPt: f.height, backingScale: Double(screen.backingScaleFactor),
            topInsetPt: f.maxY - v.maxY, bottomInsetPt: v.minY - f.minY,
            leftInsetPt: v.minX - f.minX, rightInsetPt: f.maxX - v.maxX
        )
    }

    private func grid(for view: DeskView, scale: Double) -> PixelGrid {
        let display: DisplayGeometry
        if let emulated = options.windowed {
            display = emulated.geometry(widthPt: view.bounds.width, heightPt: view.bounds.height)
        } else if let screen = NSScreen.screens.first {
            display = Self.geometry(of: screen)
        } else {
            display = DisplayGeometry(widthPt: view.bounds.width, heightPt: view.bounds.height, backingScale: scale)
        }
        return PixelGrid(display: display, pixelSize: options.pixelSize)
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
        if options.windowed == nil, let window, let screen = NSScreen.screens.first, window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
        }
        view?.syncDrawable()
        refreshGrid()
    }
}
