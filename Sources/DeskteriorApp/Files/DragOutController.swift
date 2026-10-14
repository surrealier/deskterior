import AppKit
import DeskCore
import DeskFiles
import DeskPixels
import DeskScene

/// Tokens dragged out of the desk to another app (DESIGN §3.6 Drag-out, SPIKES S4). While a carry is in hand, each
/// drag event checks the window under the pointer: once it is not ours (or at once when ⌘ was held at the press),
/// the carry is handed to an `NSDraggingSession` carrying the real file URLs with the pixel icon, and the tokens are
/// home again, as in Finder. The receiving app does the work; how the drag ended decides the rest (`DragOutRule`):
/// nothing, a copy or a link change nothing; a move hides the tokens until the mirror sees the files leave (5 s at
/// most, then whatever is still there comes back); the Dock Trash's delete (exactly `.delete`, over a Dock window)
/// waits 1.5 s and then, if the file is still there and Finder did not come forward meanwhile (a dialog of its own
/// about it), trashes it itself (`dragToTrash`, undoable); the tokens stay hidden until that trash reports. Several
/// operation bits at once count as the least consequential. We never delete anything.
final class DragOutController: NSObject, NSDraggingSource {
    let host: SceneHost
    unowned let store: Store
    unowned let effects: EffectRunner
    /// "Drag-out: Always copy" (settings, M12): offer only copying.
    var alwaysCopy = false
    /// ⌘ was down when the button went down: the carry leaves at once.
    private var commandAtPress = false
    /// The tokens of the drag the system is carrying, and the desk's window it left.
    private var outbound: [TokenKey]?
    private weak var deskWindow: NSWindow?
    /// Tokens hidden while their files are expected to leave.
    private(set) var held: Set<TokenKey> = []
    /// Finder came to the front since `since` (a dialog of its own about the files: we leave them to it). Demos
    /// answer for themselves.
    var finderCameForward: (_ since: String?) -> Bool = { before in
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return front == "com.apple.finder" && before != front
    }

    init(host: SceneHost, store: Store, effects: EffectRunner) {
        self.host = host
        self.store = store
        self.effects = effects
    }

    // MARK: From the desk view

    func mouseDown(_ event: NSEvent) {
        commandAtPress = event.modifierFlags.contains(.command)
    }

    /// After the scene saw a drag event: hands a carry that left the window to the system.
    func mouseDragged(_ event: NSEvent, in view: NSView) {
        guard outbound == nil, let keys = host.scene.carriedTokenKeys else { return }
        guard commandAtPress || !Self.pointerIsOver(view.window) else { return }
        let s = store.state
        let files = keys.compactMap { k in s.url(of: k).map { (key: k, url: $0) } }
        guard !files.isEmpty else { return }
        let image = host.scene.dragImage(for: keys).flatMap { Self.image($0, grid: host.grid) }
        host.scene.handOffCarry()
        host.modelChanged()
        let at = view.convert(event.locationInWindow, from: nil)
        let items = files.enumerated().map { i, f -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: f.url as NSURL)
            let size = image?.size ?? NSSize(width: 32, height: 32)
            let frame = NSRect(x: at.x - size.width / 2 + CGFloat(2 * i), y: at.y - size.height / 2 + CGFloat(2 * i),
                               width: size.width, height: size.height)
            item.setDraggingFrame(frame, contents: image)
            return item
        }
        outbound = files.map(\.key)
        deskWindow = view.window
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// True when the frontmost window under the pointer is `window`.
    static func pointerIsOver(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
    }

    /// The 16-px icon as a crisp image at the desk's pixel size.
    static func image(_ icon: PixelBuffer, grid: PixelGrid) -> NSImage? {
        let factor = max(1, grid.scale)
        guard let cg = icon.scaledNearest(factor).makeCGImage() else { return nil }
        let points = Double(icon.width * factor) / grid.display.backingScale
        return NSImage(cgImage: cg, size: NSSize(width: points, height: points))
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.mask(DragOutRule.offered(alwaysCopy: alwaysCopy))
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // AppKit swallowed the mouse-up: the scene's gesture ended at the hand-off already.
        guard let keys = outbound else { return }
        outbound = nil
        // Dropped back on the desk itself: its drop-in moved the tokens (a layout move); nothing is leaving.
        let under = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        let home = deskWindow.map { under == $0.windowNumber } == true
        ended(keys, home ? .none : DragOutRule.outcome(Self.outcomes(operation), overDock: Self.isDockWindow(under)))
    }

    /// Whether the window numbered `number` belongs to the Dock (its owner's process; no window titles are read).
    static func isDockWindow(_ number: Int) -> Bool {
        guard number > 0,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
              let pid = list.first?[kCGWindowOwnerPID as String] as? Int32
        else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock"
    }

    static func mask(_ outcomes: [DragOutRule.Outcome]) -> NSDragOperation {
        outcomes.reduce(into: NSDragOperation()) { mask, o in
            switch o {
            case .none: break
            case .copy: mask.insert(.copy)
            case .link: mask.insert(.link)
            case .move: mask.insert(.move)
            case .generic: mask.insert(.generic)
            case .delete: mask.insert(.delete)
            }
        }
    }

    /// The operation bits the drag ended with (`DragOutRule.outcome` reads them).
    static func outcomes(_ op: NSDragOperation) -> Set<DragOutRule.Outcome> {
        let bits: [(NSDragOperation, DragOutRule.Outcome)] = [
            (.copy, .copy), (.link, .link), (.generic, .generic), (.move, .move), (.delete, .delete),
        ]
        return Set(bits.filter { op.contains($0.0) }.map(\.1))
    }

    // MARK: After the drag

    /// What follows a drag out that ended with `outcome` (the demo runner's `dragOut` step comes here too).
    func ended(_ keys: [TokenKey], _ outcome: DragOutRule.Outcome) {
        let plan = DragOutRule.plan(outcome)
        guard case let .waitForRemoval(seconds, _) = plan, !keys.isEmpty else { return }
        let hold = Set(keys)
        held.formUnion(hold)
        host.scene.holdForDragOut(hold)
        host.modelChanged()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.waited(keys, plan, frontAtEnd: front)
        }
    }

    /// The wait is over: files still on the desk come back, or (the Dock Trash) go to the trash now, unless Finder
    /// came forward meanwhile.
    private func waited(_ keys: [TokenKey], _ plan: DragOutRule.Plan, frontAtEnd: String?) {
        let s = store.state
        let still = keys.map(s.currentKey).filter { k in
            s.tokens.contains(k) && s.url(of: k).flatMap(FileReport.identity(of:)) == k
        }
        let trash = DragOutRule.toTrash(plan, stillThere: still, finderTookOver: finderCameForward(frontAtEnd))
        let release = { [weak self] in
            guard let self else { return }
            let hold = Set(keys)
            held.subtract(hold)
            host.scene.revealDragOut(hold)
            host.modelChanged()
        }
        guard !trash.isEmpty else { return release() }
        let before = effects.files?.lastStarted
        effects.withOrigin(.dragToTrash) { store.dispatch(.requestTrash(trash)) }
        // Tokens on their way to the trash stay hidden until that trash reports (refused ones come back then).
        if let files = effects.files, let ref = files.lastStarted, ref != before {
            files.whenFinished(ref, release)
        } else {
            release()
        }
    }
}
