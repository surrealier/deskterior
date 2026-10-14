import AppKit
import DeskCore
import DeskPixels

/// A display that does not hold the desk, covered by a static wall (DESIGN §4.10 `WallScene`): a `DeskWindow` at the
/// desk's level whose layer shows `WallArt` rendered once on the CPU at art resolution and magnified by the layer
/// with nearest filtering at the display's integer scale. It is re-rendered only when its size or the light changes
/// (`WallArt.signature`), so it costs nothing while idle. Files dropped on it go to the monitor; a right-click opens
/// the desk menu.
final class WallController {
    let displayID: UInt32
    let window: DeskWindow
    let view: WallView
    private(set) var grid: PixelGrid
    private var signature = ""

    init(display: DisplayInfo, level: LaunchOptions.Level, pixelSize: PixelSize) {
        displayID = display.id
        window = DeskWindow(frame: display.frame.cg, level: level)
        grid = PixelGrid(display: display.geometry, pixelSize: pixelSize)
        view = WallView(frame: NSRect(origin: .zero, size: display.frame.cg.size))
        window.contentView = view
        window.setAccessibilityLabel(tr(.axWall))
    }

    /// Follows the display's new frame or scale.
    func update(display: DisplayInfo, pixelSize: PixelSize) {
        if window.frame != display.frame.cg { window.setFrame(display.frame.cg, display: false) }
        let g = PixelGrid(display: display.geometry, pixelSize: pixelSize)
        if g != grid {
            grid = g
            signature = ""
        }
    }

    /// Renders the wall for `state` unless it would look the same as what is shown.
    func render(_ state: RoomState) {
        let sig = WallArt.signature(grid: grid, state: state)
        guard sig != signature else { return }
        signature = sig
        view.show(WallArt.render(grid: grid, state: state).makeCGImage(), grid: grid)
    }

    func show() { window.orderFrontRegardless() }
    func hide() { window.orderOut(nil) }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

/// The wall's content: one layer with the art-resolution image, magnified ×S (nearest) and cropped like the desk's
/// canvas (`PixelGrid`), a drop target for files and a source of the desk menu.
final class WallView: NSView {
    /// Files dropped here (copy when ⌥ was held).
    var onDrop: (([URL], _ copy: Bool) -> Void)?
    /// A right-click (or VoiceOver's Show Desk Menu) at a view point.
    var onMenu: ((NSPoint) -> Void)?
    private var image: CGImage?
    private var grid: PixelGrid?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WallView is built in code")
    }

    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ image: CGImage?, grid: PixelGrid) {
        self.image = image
        self.grid = grid
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = Ink.neutral1.color.cgColor
        layer.contents = image
        layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        // Show the frame's part of the canvas: S device px per art px, the crop split as in the desk's grid.
        if let grid, grid.artSize.w > 0, grid.artSize.h > 0 {
            let w = Double(grid.artSize.w * grid.scale), h = Double(grid.artSize.h * grid.scale)
            layer.contentsRect = CGRect(
                x: Double(grid.cropLeft) / w, y: Double(grid.cropTop) / h,
                width: Double(grid.display.frameWidthPx) / w, height: Double(grid.display.frameHeightPx) / h
            )
        }
    }

    // MARK: Menu

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onMenu?(convert(event.locationInWindow, from: nil)) }
    }

    // MARK: Drops (routed to the monitor)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop?(urls, NSEvent.modifierFlags.contains(.option))
        return true
    }

    private func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !Self.fileURLs(sender.draggingPasteboard).isEmpty, onDrop != nil else { return [] }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { tr(.axWall) }
    override func accessibilityHelp() -> String? { tr(.axWallHelp) }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: tr(.axShowDeskMenu)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onMenu?(NSPoint(x: self.bounds.midX, y: self.bounds.midY))
            }
            return true
        }]
    }
}

extension RGBA8 {
    /// The colour as a `CGColor` (sRGB).
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}
