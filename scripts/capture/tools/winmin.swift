import AppKit
import ApplicationServices
// winmin APP TITLE yes|no: minimizes or restores the app's window with that exact title.
let a = CommandLine.arguments
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == a[1] }) else { print("no app"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
var v: CFTypeRef?; AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v)
for w in (v as? [AXUIElement]) ?? [] {
    var t: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
    if (t as? String) == a[2] {
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, (a[3] == "yes" ? kCFBooleanTrue : kCFBooleanFalse)!)
        print("\(a[3] == "yes" ? "minimized" : "restored") \(a[2])"); exit(0)
    }
}
print("no window \(a[2])"); exit(1)
