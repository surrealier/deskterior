import AppKit
import DeskCore
import DeskScene
import Metal
import QuartzCore
import QuickLookUI

/// The desk's content view (DESIGN §4.5): backed by a `CAMetalLayer` (bgra8Unorm, sRGB, framebuffer-only) whose
/// drawable is kept at the backing size, and the source of `InputEvent`s and `KeyCommand`s. Pointer locations go
/// points (y-up) → y-down view points → canvas art px through the host's `PixelGrid`. Keys (Errata 1): Space
/// Quick Look, ⌘O/⌘↓ open, ⌘C copy file URLs, ⌘A select the page, ⌘F Find, ⌘Z/⇧⌘Z undo/redo, Esc, arrows; there
/// is no ⌘⌫ and no other destructive key equivalent. It is also the Quick Look panel's controller.
final class DeskView: NSView {
    let metalLayer = CAMetalLayer()
    weak var host: SceneHost?
    /// Device px per point: nil follows the window (desk mode); a value emulates a display (`--windowed`).
    var emulatedScale: Double?
    /// Called when the drawable size or scale changes.
    var onGeometryChange: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var reportedSize = CGSize.zero
    private var reportedScale = 0.0

    init(frame: NSRect, device: any MTLDevice) {
        super.init(frame: frame)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.magnificationFilter = .nearest
        metalLayer.minificationFilter = .nearest
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DeskView is built in code")
    }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Device px per point.
    var deviceScale: Double { emulatedScale ?? Double(window?.backingScaleFactor ?? 2) }

    override func layout() {
        super.layout()
        syncDrawable()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawable()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDrawable()
    }

    /// Re-asserts `drawableSize = bounds × scale` and `contentsScale` (AppKit may reset them), and reports
    /// changes to `onGeometryChange`.
    func syncDrawable() {
        let scale = deviceScale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        guard size != reportedSize || scale != reportedScale else { return }
        reportedSize = size
        reportedScale = scale
        onGeometryChange?()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        send(.down, event)
    }

    override func mouseUp(with event: NSEvent) { send(.up, event) }
    override func mouseDragged(with event: NSEvent) { send(.drag, event) }
    override func mouseMoved(with event: NSEvent) { send(.move, event) }

    override func rightMouseDown(with event: NSEvent) {
        // The scene answers with a `SceneRequest.menu`, which the app shows through `showMenu`.
        send(.rightDown, event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let grid = host?.grid else { return }
        // Points (lines are ~10 pt) → art px, y-down: positive moves content down/right.
        let perLine: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let artPerPoint = Float(1 / grid.pointsPerArtPx)
        let delta = SIMD2(Float(event.scrollingDeltaX * perLine), Float(event.scrollingDeltaY * perLine)) * artPerPoint
        send(.scroll, event, scroll: delta)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if let command = Self.command(for: event) {
            host?.handleKey(command)
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command), let command = Self.command(for: event)
        else { return super.performKeyEquivalent(with: event) }
        host?.handleKey(command)
        return true
    }

    static func command(for event: NSEvent) -> KeyCommand? {
        KeyCommand.from(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                        mods: modifiers(event.modifierFlags))
    }

    // The hidden main menu's Edit items (Errata 1) route here too.
    @objc func undo(_ sender: Any?) { host?.handleKey(.undo) }
    @objc func redo(_ sender: Any?) { host?.handleKey(.redo) }
    @objc func copy(_ sender: Any?) { host?.handleKey(.copy) }
    @objc override func selectAll(_ sender: Any?) { host?.handleKey(.selectAll) }

    // MARK: Menus

    /// Pops `menu` up at a canvas art point.
    func showMenu(_ menu: NSMenu, atArt p: SIMD2<Float>) {
        menu.popUp(positioning: nil, at: viewPoint(fromArt: p), in: self)
    }

    /// The view point (y-up) of a canvas art point.
    func viewPoint(fromArt p: SIMD2<Float>) -> NSPoint {
        guard let grid = host?.grid else { return .zero }
        let s = Double(grid.scale), backing = grid.display.backingScale
        let x = (Double(p.x) * s - Double(grid.cropLeft)) / backing
        let y = (Double(p.y) * s - Double(grid.cropTop)) / backing
        return NSPoint(x: x, y: Double(bounds.height) - y)
    }

    // MARK: Quick Look (the panel finds us in the responder chain)

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = QuickLookSource.shared }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    // MARK: Conversion

    @discardableResult
    private func send(_ kind: InputEvent.Kind, _ event: NSEvent, scroll: SIMD2<Float> = .zero) -> InputEvent? {
        guard let host else { return nil }
        let isKey = kind == .key
        let inWindow = isKey ? (window?.mouseLocationOutsideOfEventStream ?? .zero) : event.locationInWindow
        let local = convert(inWindow, from: nil)
        let viewPoint = SIMD2(Double(local.x), Double(bounds.height - local.y))
        let e = InputEvent(
            kind, art: ArtSpace.canvasArtPoint(fromViewPoint: viewPoint, grid: host.grid),
            mods: Self.modifiers(event.modifierFlags),
            clickCount: kind == .down || kind == .up || kind == .rightDown ? event.clickCount : 0,
            scroll: scroll, t: event.timestamp, keyCode: isKey ? event.keyCode : 0
        )
        host.handle(e)
        return e
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> InputEvent.Modifiers {
        var m: InputEvent.Modifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }
}
