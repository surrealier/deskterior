import AppKit
import ApplicationServices
// winpos APP X Y W H [TITLE]: moves and resizes the app's window (titled TITLE, else its first) via Accessibility.
// winpos APP list: prints the app's windows.
let a = CommandLine.arguments
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == a[1] || $0.bundleIdentifier == a[1] }) else { print("no app"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
var v: CFTypeRef?
AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v)
let wins = (v as? [AXUIElement]) ?? []
func title(_ w: AXUIElement) -> String { var t: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t); return t as? String ?? "" }
if a[2] == "list" { for w in wins { print("window:", title(w)) }; exit(0) }
let want = a.count > 6 ? a[6] : nil
guard let w = wins.first(where: { want == nil || title($0) == want }) else { print("no window"); exit(1) }
var p = CGPoint(x: Double(a[2])!, y: Double(a[3])!), s = CGSize(width: Double(a[4])!, height: Double(a[5])!)
AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
print("moved", title(w))
