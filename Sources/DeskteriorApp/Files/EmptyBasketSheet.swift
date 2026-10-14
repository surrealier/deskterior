import AppKit
import DeskCore
import DeskPixels

/// The confirmation before Empty Wastebasket… (DESIGN §2.2 E8, §3.5): how many items, the first names (up to
/// `MenuSpec.listLimit`, then "and N more"), and what it means: the basket only hides files; this moves them to the
/// Trash, and Undo or Finder's Put Back returns them. **Cancel is the default button** (Return) and Escape cancels
/// too; "Move to Trash" must be chosen. The basket never empties itself.
enum EmptyBasketSheet {
    /// The question, e.g. "Move the 5 items in the wastebasket to the Trash?".
    static func message(count: Int) -> String {
        L10n.tr(count == 1 ? "Move the item in the wastebasket to the Trash?" : "Move the \(count) items in the wastebasket to the Trash?")
    }

    /// The names, one per line, then "and N more", then what happens.
    static func details(names: [String], more: Int) -> String {
        var lines = names.map { "• \($0)" }
        if more > 0 { lines.append(L10n.tr("and \(more) more")) }
        lines.append("")
        lines.append(L10n.tr("The wastebasket only hides files on the desk. This moves them to the Trash; Undo or Finder's "
            + "Put Back returns them."))
        return lines.joined(separator: "\n")
    }

    /// The alert, laid out: Cancel first (the default, Return), then the destructive "Move to Trash".
    static func alert(_ kind: ConfirmKind, count: Int) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch kind {
        case let .emptyWastebasket(names, more):
            alert.messageText = message(count: count)
            alert.informativeText = details(names: names, more: more)
        }
        let cancel = alert.addButton(withTitle: tr(.cancel))
        cancel.keyEquivalent = "\r"
        let trash = alert.addButton(withTitle: tr(.moveToTrash))
        trash.keyEquivalent = ""
        trash.hasDestructiveAction = true
        if let icon = basketIcon() { alert.icon = icon }
        alert.layout()
        return alert
    }

    /// Asks (app-modal, after the current event), then calls `done(true)` only for "Move to Trash". Return is
    /// Cancel's key, so AppKit gives Escape to no button: a key monitor maps Escape (and ⌘.) to Cancel while the
    /// alert runs.
    static func present(_ kind: ConfirmKind, count: Int, done: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            NSApp.activate()
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard isCancelKey(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                  command: event.modifierFlags.contains(.command)) else { return event }
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
                return nil
            }
            let answer = alert(kind, count: count).runModal()
            if let monitor { NSEvent.removeMonitor(monitor) }
            done(answer == .alertSecondButtonReturn)
        }
    }

    /// Escape (key code 53) or ⌘. cancels.
    static func isCancelKey(keyCode: UInt16, characters: String?, command: Bool) -> Bool {
        keyCode == 53 || (command && characters == ".")
    }

    /// The sheet drawn offscreen as PNG data (demo review); nothing is shown. An offscreen window is never key, so
    /// AppKit draws no default button there: a caption under the sheet says which button Return and Escape answer.
    static func picture(_ kind: ConfirmKind, count: Int) -> Data? {
        _ = NSApplication.shared
        let a = alert(kind, count: count)
        guard let view = a.window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let sheet = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: sheet)
        let caption: CGFloat = 30
        let size = NSSize(width: view.bounds.width, height: view.bounds.height + caption)
        let scale = CGFloat(sheet.pixelsWide) / max(1, view.bounds.width)
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: sheet.pixelsWide, pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        out.size = size // Points, so the context draws at the sheet's scale.
        guard let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        sheet.draw(in: NSRect(x: 0, y: caption, width: size.width, height: view.bounds.height))
        let text = "Default: Cancel (Return, Esc)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let w = text.size(withAttributes: attributes).width
        text.draw(at: NSPoint(x: (size.width - w) / 2, y: 9), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .png, properties: [:])
    }

    /// The pixel wastebasket, ×4 (nearest), as the alert's icon.
    private static func basketIcon() -> NSImage? {
        let back = PropArt.wastebasketBack().image, front = PropArt.wastebasketFront().image
        var c = PixelCanvas(width: back.width, height: back.height)
        c.blit(back, at: .zero)
        c.blit(front, at: .zero)
        guard let cg = c.buffer.scaledNearest(4).makeCGImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: back.width * 2, height: back.height * 2))
    }
}
