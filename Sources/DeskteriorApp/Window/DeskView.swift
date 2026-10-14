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
    // MARK: system (M12)
    /// Called before a click, drag, scroll, key or VoiceOver press reaches the scene (not on hover), so a desk
    /// frozen on battery wakes first (`SystemGate.interacting`).
    var onInput: (() -> Void)?

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
        dragOut?.mouseDown(event) // MARK: files
    }

    override func mouseUp(with event: NSEvent) { send(.up, event) }
    override func mouseDragged(with event: NSEvent) {
        send(.drag, event)
        dragOut?.mouseDragged(event, in: self) // MARK: files
    }
    override func mouseMoved(with event: NSEvent) { send(.move, event) }
    // MARK: mat
    /// A modifier key went down or up: a move at the pointer, so ⌥ over the mat shows its handles without a move.
    override func flagsChanged(with event: NSEvent) {
        send(.move, event)
        super.flagsChanged(with: event)
    }

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
            onInput?()
            host?.handleKey(command)
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command), let command = Self.command(for: event)
        else { return super.performKeyEquivalent(with: event) }
        onInput?()
        host?.handleKey(command)
        return true
    }

    static func command(for event: NSEvent) -> KeyCommand? {
        KeyCommand.from(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                        mods: modifiers(event.modifierFlags))
    }

    // The hidden main menu's Edit items (Errata 1) route here too.
    @objc func undo(_ sender: Any?) { onInput?(); host?.handleKey(.undo) }
    @objc func redo(_ sender: Any?) { onInput?(); host?.handleKey(.redo) }
    @objc func copy(_ sender: Any?) { onInput?(); host?.handleKey(.copy) }
    @objc override func selectAll(_ sender: Any?) { onInput?(); host?.handleKey(.selectAll) }

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

    // MARK: Accessibility (DESIGN §4.5)

    /// The scene's items and the elements built from them; rebuilt only when the items change.
    private var axItems: [AXItem] = []
    private var axElements: [DeskAccessibilityElement] = []

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Desk" }

    override func accessibilityChildren() -> [Any]? {
        let items = host?.scene.accessibilityItems() ?? []
        if items != axItems {
            axItems = items
            axElements = items.map { item in
                var open: DeskAccessibilityElement.Action?
                if let key = item.token { open = { [weak self] in self?.accessibilityOpen(key) } }
                return DeskAccessibilityElement(item: item, parent: self, press: { [weak self] in self?.accessibilityPress(item) },
                                                open: open)
            }
            // M12: more custom actions (Quick Look, Show in Finder, Move to Monitor).
            DeskAccessibility.decorate?(axElements)
        }
        for e in axElements { e.setAccessibilityFrameInParentSpace(viewRect(fromArt: e.item.frame)) }
        return axElements
    }

    /// The view rect (y-up points) of a canvas art rect.
    func viewRect(fromArt r: ArtRect) -> NSRect {
        let a = viewPoint(fromArt: SIMD2(Float(r.minX), Float(r.minY)))
        let b = viewPoint(fromArt: SIMD2(Float(r.maxX), Float(r.maxY)))
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func accessibilityPress(_ item: AXItem) {
        guard let host else { return }
        onInput?()
        host.scene.accessibilityPress(item, time: ProcessInfo.processInfo.systemUptime)
        host.modelChanged()
    }

    private func accessibilityOpen(_ key: TokenKey) {
        host?.scene.accessibilityOpen(key)
    }

    // MARK: Quick Look (the panel finds us in the responder chain)

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = QuickLookSource.shared }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    // MARK: files

    /// Drags out to other apps, and files dropped in from Finder (DESIGN §3.6); set by the app.
    var dragOut: DragOutController?
    var dropIn: DropInController? {
        didSet {
            if dropIn == nil { unregisterDraggedTypes() } else { registerForDraggedTypes([.fileURL]) }
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { dropInUpdate(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { dropInUpdate(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropIn?.dragEnded() }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let dropIn else { return false }
        let urls = DropInController.fileURLs(sender.draggingPasteboard)
        let copy = DropInController.wantsCopy(sender.draggingSourceOperationMask, modifiers: NSEvent.modifierFlags)
        return dropIn.drop(urls, at: artPoint(windowPoint: sender.draggingLocation), copy: copy)
    }

    private func dropInUpdate(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let dropIn else { return [] }
        let urls = DropInController.fileURLs(sender.draggingPasteboard)
        let copy = DropInController.wantsCopy(sender.draggingSourceOperationMask, modifiers: NSEvent.modifierFlags)
        return dropIn.dragged(urls, at: artPoint(windowPoint: sender.draggingLocation), copy: copy,
                              drag: sender.draggingSequenceNumber)
    }

    /// The canvas art point under a window point.
    private func artPoint(windowPoint: NSPoint) -> SIMD2<Float> {
        guard let host else { return .zero }
        let local = convert(windowPoint, from: nil)
        return ArtSpace.canvasArtPoint(fromViewPoint: SIMD2(Double(local.x), Double(bounds.height - local.y)), grid: host.grid)
    }

    // MARK: Conversion

    @discardableResult
    private func send(_ kind: InputEvent.Kind, _ event: NSEvent, scroll: SIMD2<Float> = .zero) -> InputEvent? {
        guard let host else { return nil }
        if kind != .move { onInput?() }
        let isKey = kind == .key
        // Key and modifier events carry no pointer location of their own.
        let fromStream = isKey || event.type == .flagsChanged
        let inWindow = fromStream ? (window?.mouseLocationOutsideOfEventStream ?? .zero) : event.locationInWindow
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

/// One desk control or token for VoiceOver: a labelled button whose press clicks it, and Open for tokens.
/// AppKit calls it on the main thread.
nonisolated final class DeskAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    typealias Action = @MainActor @Sendable () -> Void
    let item: AXItem
    private let press: Action

    init(item: AXItem, parent: NSView, press: @escaping Action, open: Action?) {
        self.item = item
        self.press = press
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityLabel(item.label)
        switch item.role {
        case .button, .token:
            setAccessibilityRole(.button)
            if item.role == .token { setAccessibilityRoleDescription("file") }
        case .container, .group:
            setAccessibilityRole(.group)
        }
        if let open {
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Open") {
                    MainActor.assumeIsolated { open() }
                    return true
                },
            ])
        }
    }

    override func accessibilityPerformPress() -> Bool {
        let press = press
        MainActor.assumeIsolated { press() }
        return true
    }
}
