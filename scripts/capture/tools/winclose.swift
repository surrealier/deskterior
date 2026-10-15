import AppKit
import ApplicationServices
// winclose APP TITLE: presses the close button of the app's window with that exact title.
let a = CommandLine.arguments
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == a[1] }) else { exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
var v: CFTypeRef?; AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v)
for w in (v as? [AXUIElement]) ?? [] {
    var t: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
    guard (t as? String) == a[2] else { continue }
    var b: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &b)
    if let b { AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString); print("closed \(a[2])"); exit(0) }
}
print("no window \(a[2])"); exit(1)
