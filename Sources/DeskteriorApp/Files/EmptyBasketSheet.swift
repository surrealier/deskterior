import AppKit
import DeskCore
import DeskPixels

/// The confirmation before Empty Wastebasket… (DESIGN §2.2 E8, §3.5): how many items, the first names (up to
/// `MenuSpec.listLimit`, then "and N more"), and what it means: the basket only hides files; this moves them to the
/// Trash, and Undo puts them back. **Cancel is the default button** (Return); "Move to Trash" must be chosen. The
/// basket never empties itself.
enum EmptyBasketSheet {
    /// The question, e.g. "Move the 5 items in the wastebasket to the Trash?".
    static func message(count: Int) -> String {
        count == 1 ? "Move the item in the wastebasket to the Trash?" : "Move the \(count) items in the wastebasket to the Trash?"
    }

    /// The names, one per line, then "and N more", then what happens.
    static func details(names: [String], more: Int) -> String {
        var lines = names.map { "• \($0)" }
        if more > 0 { lines.append("and \(more) more") }
        lines.append("")
        lines.append("The wastebasket only hides files on the desk. This moves them to the Trash; Undo puts them back.")
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
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.keyEquivalent = ""
        trash.hasDestructiveAction = true
        if let icon = basketIcon() { alert.icon = icon }
        alert.layout()
        return alert
    }

    /// Asks (app-modal, after the current event), then calls `done(true)` only for "Move to Trash".
    static func present(_ kind: ConfirmKind, count: Int, done: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            NSApp.activate()
            let answer = alert(kind, count: count).runModal()
            done(answer == .alertSecondButtonReturn)
        }
    }

    /// The sheet drawn offscreen as PNG data (demo review); nothing is shown.
    static func picture(_ kind: ConfirmKind, count: Int) -> Data? {
        _ = NSApplication.shared
        let a = alert(kind, count: count)
        guard let view = a.window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
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
