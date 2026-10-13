import AppKit
import DeskCore
import DeskPixels

/// The menu-bar status item (DESIGN §4.9; M2: Pause/Resume Desk and Quit) with a 16-pt pixel template glyph.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let pauseItem: NSMenuItem
    private let isPaused: () -> Bool
    private let togglePause: () -> Void

    init(isPaused: @escaping () -> Bool, togglePause: @escaping () -> Void) {
        self.isPaused = isPaused
        self.togglePause = togglePause
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        pauseItem = NSMenuItem(title: "Pause Desk", action: #selector(StatusMenu.togglePauseAction), keyEquivalent: "")
        super.init()

        item.button?.image = Self.templateImage()
        item.button?.toolTip = "Deskterior"
        pauseItem.target = self
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let quit = #selector(NSApplication.terminate(_:))
        menu.addItem(NSMenuItem(title: "Quit Deskterior", action: quit, keyEquivalent: "q"))
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.title = isPaused() ? "Resume Desk" : "Pause Desk"
    }

    @objc private func togglePauseAction() {
        togglePause()
    }

    /// 16×16 desk with a monitor (template: only alpha matters).
    static let glyph = IndexedSprite("""
        ................
        ..kkkkkkkkkkkk..
        ..k..........k..
        ..k.kk.......k..
        ..k.k........k..
        ..k..........k..
        ..k..........k..
        ..kkkkkkkkkkkk..
        .......kk.......
        .....kkkkkk.....
        ................
        kkkkkkkkkkkkkkkk
        kkkkkkkkkkkkkkkk
        .kk..........kk.
        .kk..........kk.
        .kk..........kk.
        """)

    /// The glyph as a 16-pt template image with exact 1× and 2× pixel representations.
    static func templateImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        let base = glyph.render()
        for factor in [1, 2] {
            guard let cg = base.scaledNearest(factor).makeCGImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: 16, height: 16)
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }
}
