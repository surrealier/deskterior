import AppKit
import ApplicationServices
// menuitems APP MENU: lists the item titles (and enabled state) of APP's menu-bar MENU without pressing anything.
let a = CommandLine.arguments
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == a[1] }) else { print("no app"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func title(_ e: AXUIElement) -> String { attr(e, kAXTitleAttribute) as? String ?? "" }
guard let bar = attr(ax, kAXMenuBarAttribute) else { print("no menu bar"); exit(1) }
for top in kids(bar as! AXUIElement) where title(top) == a[2] {
    for menu in kids(top) { for item in kids(menu) { print(title(item), (attr(item, kAXEnabledAttribute) as? Bool ?? false) ? "" : "(disabled)") } }
}
