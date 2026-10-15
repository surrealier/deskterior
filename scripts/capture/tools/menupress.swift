import AppKit
import ApplicationServices
// menupress APP MENU ITEM: presses APP's menu-bar MENU ▸ ITEM if that item exists and is enabled (prints what it did).
let a = CommandLine.arguments
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == a[1] }) else { print("no app"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func title(_ e: AXUIElement) -> String { attr(e, kAXTitleAttribute) as? String ?? "" }
AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
usleep(400_000)
guard let bar = attr(ax, kAXMenuBarAttribute) else { print("no menu bar"); exit(1) }
let barEl = bar as! AXUIElement
for top in kids(barEl) where title(top) == a[2] {
    for menu in kids(top) {
        for item in kids(menu) where title(item) == a[3] {
            let enabled = attr(item, kAXEnabledAttribute) as? Bool ?? false
            if enabled { AXUIElementPerformAction(item, kAXPressAction as CFString); print("pressed \(a[3])") } else { print("disabled \(a[3])") }
            exit(0)
        }
    }
}
print("absent \(a[3])")
