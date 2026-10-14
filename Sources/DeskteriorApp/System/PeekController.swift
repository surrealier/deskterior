import AppKit
import DeskCore
import DeskPixels
import DeskScene

/// Peek Desk (DESIGN §2.2 E16): the desk window floats above other apps' windows and the app activates, with a pixel
/// "× Done" button at the top right of the visible desk. It ends on Esc (on the desk), on ×, on the hotkey or the menu
/// item again, or when another app activates. A paused desk resumes to be peeked at. Meanwhile the app's own windows
/// (Settings, About, Find Item, Quick Look) sit just above the floating desk (`PeekPolicy`, `AppWindow.setLevel`).
final class PeekController {
    private weak var displays: DisplayManager?
    private(set) var isPeeking = false
    /// Peeking started or ended (the system gate hears it).
    var onChange: ((Bool) -> Void)?
    /// Asked before peeking: resume a paused desk.
    var resumeIfPaused: (() -> Void)?
    private var button: PeekDoneButton?
    private var keyMonitor: Any?
    private var activationToken: (any NSObjectProtocol)?

    init(displays: DisplayManager) {
        self.displays = displays
    }

    func toggle() {
        if isPeeking { end() } else { begin() }
    }

    func begin() {
        guard !isPeeking, let displays, let view = displays.view else { return }
        resumeIfPaused?()
        isPeeking = true
        displays.setPeeking(true)
        if let desk = displays.window {
            let level = PeekPolicy.appWindowLevel(peeking: true, deskLevel: desk.level.rawValue,
                                                  normal: NSWindow.Level.normal.rawValue)
            AppWindow.setLevel(NSWindow.Level(rawValue: level))
        }
        let b = PeekDoneButton(grid: displays.host?.grid) { [weak self] in self?.end() }
        view.addSubview(b)
        b.place(in: view)
        button = b
        // Esc on the desk ends it (and is not passed on: it would also clear the selection); in the app's other
        // windows it keeps its meaning (Find Item closes).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.isPeeking, event.window === self.displays?.window else {
                return event
            }
            self.end()
            return nil
        }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                guard pid != ProcessInfo.processInfo.processIdentifier else { return }
                self?.end()
            }
        }
        NSAccessibility.post(element: b, notification: .created)
        onChange?(true)
        Log.info("peek: on")
    }

    func end() {
        guard isPeeking else { return }
        isPeeking = false
        button?.removeFromSuperview()
        button = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        displays?.setPeeking(false)
        AppWindow.setLevel(.normal)
        onChange?(false)
        Log.info("peek: off")
    }

    /// The grid changed: keep the button in the corner.
    func relayout() {
        guard let button, let view = displays?.view else { return }
        button.grid = displays?.host?.grid
        button.place(in: view)
    }
}

/// The pixel "× Done" button: Galmuri9 on a dark rounded tab, drawn at art resolution and magnified ×S by its
/// layer with nearest filtering, at the top right of the desk's visible area.
final class PeekDoneButton: NSView {
    var grid: PixelGrid?
    private let action: () -> Void
    private var image: CGImage?
    private var artSize = ArtSize(0, 0)

    init(grid: PixelGrid?, action: @escaping () -> Void) {
        self.grid = grid
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        if let art = Self.art() {
            artSize = art.size
            image = art.makeCGImage()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PeekDoneButton is built in code")
    }

    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
    }

    /// Sits 4 art px inside the top-right corner of the visible art rect.
    func place(in view: DeskView) {
        guard let grid else { return }
        let r = grid.visibleArtRect
        let art = ArtRect(r.maxX - artSize.w - 4, r.minY + 4, artSize.w, artSize.h)
        frame = view.viewRect(fromArt: art)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    /// The button's pixels (nil without the font).
    static func art() -> PixelBuffer? {
        guard let font = PixelFont.galmuri9 else { return nil }
        let text = font.renderLabel(L10n.text(.peekDone), color: Ink.neutral9.color, shadow: Ink.neutral0.color)
        let w = text.width + 10, h = text.height + 6
        var c = PixelCanvas(width: w, height: h + 1)
        c.roundedRectFill(ArtRect(0, 1, w, h), radius: 2, .neutral0)
        c.roundedRectFill(ArtRect(0, 0, w, h), radius: 2, .walnut4)
        c.roundedRectFill(ArtRect(1, 1, w - 2, h - 2), radius: 1, .neutral1)
        c.blit(text, at: ArtPoint(5, 3))
        return c.buffer
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { L10n.text(.peekDoneAX) }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
