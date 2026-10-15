import CoreGraphics
import Foundation
// allwin [OWNER]: lists all windows (on- and off-screen) with layer, bounds, on-screen flag and title.
let want = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
for w in list {
    let o = w[kCGWindowOwnerName as String] as? String ?? "?"
    if let want, o != want { continue }
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let on = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    print("\(o)\tid \(w[kCGWindowNumber as String] ?? 0)\tlayer \(w[kCGWindowLayer as String] ?? "?")\t\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))\ton \(on)\t\(w[kCGWindowName as String] ?? "")")
}
