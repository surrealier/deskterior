import AppKit
import ApplicationServices
let app = NSWorkspace.shared.runningApplications.first { $0.localizedName == CommandLine.arguments[1] }!
let ax = AXUIElementCreateApplication(app.processIdentifier)
var v: CFTypeRef?; AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v)
for w in (v as? [AXUIElement]) ?? [] {
    var t: CFTypeRef?, p: CFTypeRef?, s: CFTypeRef?, m: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t); AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p)
    AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s); AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m)
    var pt = CGPoint.zero, sz = CGSize.zero
    if let p { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }; if let s { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
    print("\(t as? String ?? "") pos \(pt) size \(sz) minimized \(m as? Bool ?? false)")
}
