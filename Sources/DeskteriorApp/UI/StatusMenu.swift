import AppKit
import DeskCore
import DeskPixels

/// The menu-bar status item (DESIGN §4.9) with a 16-pt pixel template glyph. Its menu is rebuilt from
/// `MenuSpec.status` each time it opens, so check marks, the undo label and the wastebasket count are current;
/// the same items live on the bare wall's right-click menu for when menu-bar extras are hidden.
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
