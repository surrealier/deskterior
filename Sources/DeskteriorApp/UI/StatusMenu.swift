import AppKit
import DeskCore
import DeskPixels

/// The menu-bar status item (DESIGN §4.9) with an 18-pt pixel template glyph (`StatusGlyphArt`). Its menu is
/// rebuilt from `MenuSpec.status` each time it opens, so check marks, the undo label and the wastebasket count are
/// current; the same items live on the bare wall's right-click menu for when menu-bar extras are hidden.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let bridge: MenuBridge
    private let spec: () -> MenuSpec

    init(spec: @escaping () -> MenuSpec, perform: @escaping (MenuCommand) -> Void) {
        self.spec = spec
        bridge = MenuBridge(perform: perform)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = Self.templateImage()
        item.button?.toolTip = "Deskterior"
        menu.delegate = self
        bridge.fill(menu, with: spec())
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        bridge.fill(menu, with: spec())
    }

    // MARK: w6-polish
    /// The glyph (`StatusGlyphArt`) as an 18-pt template image with its own 1× and 2× pixel representations.
    static func templateImage() -> NSImage {
        let pt = CGFloat(StatusGlyphArt.points)
        let image = NSImage(size: NSSize(width: pt, height: pt))
        for scale in [1, 2] {
            guard let cg = StatusGlyphArt.image(scale: scale).makeCGImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: pt, height: pt)
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }
}
