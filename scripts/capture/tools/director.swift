import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// A tiny input director for real-screen captures of Deskterior.
//   director run SCENE.json [--dry-run]   performs steps (global screen points, top-left origin)
//   director hide STATEFILE               hides every regular app but Finder and Deskterior, remembering them
//   director unhide STATEFILE             unhides what `hide` hid
//   director windows                      lists on-screen windows (owner, layer, bounds)
//   director focused                      prints the app that has keyboard focus
// Safety: aborts if the cursor is not where the director left it (the user moved the mouse), if a mouse-down
// would land on a window that is not Deskterior's or Finder's, or after the scene's time limit; on abort it
// releases the mouse button.

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let allowedOwners: Set<String> = ["Deskterior", "Finder"]

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data("director: \(s)\n".utf8)); exit(1) }

struct Abort: Error { let why: String }

final class Director {
    let dry: Bool
    let src = CGEventSource(stateID: .hidSystemState)
    var last: CGPoint?
    var held = false
    var heldFlags: CGEventFlags = []
    let deadline: Date

    init(dry: Bool, limit: Double) {
        self.dry = dry
        deadline = Date().addingTimeInterval(limit)
    }

    var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func checkUser() throws {
        if Date() > deadline { throw Abort(why: "time limit") }
        guard !dry, let last else { return }
        let c = cursor
        if abs(c.x - last.x) > 4 || abs(c.y - last.y) > 4 { throw Abort(why: "the cursor moved (user input?) \(c) vs \(last)") }
    }

    func owner(at p: CGPoint) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for w in list {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = w[kCGWindowLayer as String] as? Int, layer < 1000 else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            if alpha > 0.01, r.contains(p) { return w[kCGWindowOwnerName as String] as? String }
        }
        // The desk sits below the desktop-icon level, which `excludeDesktopElements` leaves out.
        return "Deskterior?"
    }

    func post(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1, flags: CGEventFlags = []) {
        if dry { print("  \(type.rawValue) \(Int(p.x)),\(Int(p.y)) clicks \(clicks) flags \(flags.rawValue)"); last = p; return }
        let button: CGMouseButton = (type == .rightMouseDown || type == .rightMouseUp) ? .right : .left
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
        if type == .leftMouseDown || type == .leftMouseDragged { e.setDoubleValueField(.mouseEventPressure, value: 1) }
        e.flags = flags
        e.post(tap: .cghidEventTap)
        last = p
    }

    func flagsEvent(_ flags: CGEventFlags) {
        if dry { print("  flags \(flags.rawValue)"); return }
        guard let e = CGEvent(source: src) else { return }
        e.type = .flagsChanged
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    static func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

    /// Moves along `points` (the first is the current position) in `duration` seconds, eased, with a slight arc.
    func glide(_ points: [CGPoint], duration: Double, dragging: Bool, flags: CGEventFlags, linear: Bool = false) throws {
        guard points.count >= 2 else { return }
        var lengths: [Double] = [0]
        for i in 1..<points.count { lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
        let total = max(lengths.last!, 1)
        let steps = max(2, Int(duration * 120))
        for s in 1...steps {
            try checkUser()
            let d = (linear ? Double(s) / Double(steps) : Self.ease(Double(s) / Double(steps))) * total
            var i = 1
            while i < points.count - 1, lengths[i] < d { i += 1 }
            let seg = max(lengths[i] - lengths[i - 1], 0.0001)
            let t = min(1, max(0, (d - lengths[i - 1]) / seg))
            let a = points[i - 1], b = points[i]
            // A small bow perpendicular to the segment, largest mid-way.
            let bow = sin(t * .pi) * min(18, hypot(b.x - a.x, b.y - a.y) * 0.06)
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
            let nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len
            let p = CGPoint(x: a.x + (b.x - a.x) * t + nx * bow, y: a.y + (b.y - a.y) * t + ny * bow)
            post(dragging ? .leftMouseDragged : .mouseMoved, p, flags: flags)
            if !dry { usleep(useconds_t(duration / Double(steps) * 1_000_000)) }
        }
    }

    func release() {
        if held, let p = last {
            post(.leftMouseUp, p, flags: [])
            held = false
        }
        if heldFlags != [] { flagsEvent([]); heldFlags = [] }
    }

    func point(_ v: Any?) throws -> CGPoint {
        guard let a = v as? [Double], a.count == 2 else { throw Abort(why: "bad point \(String(describing: v))") }
        return CGPoint(x: a[0], y: a[1])
    }

    func flags(_ v: Any?) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in (v as? [String]) ?? [] {
            switch m {
            case "cmd": f.insert(.maskCommand)
            case "opt": f.insert(.maskAlternate)
            case "shift": f.insert(.maskShift)
            case "ctrl": f.insert(.maskControl)
            default: break
            }
        }
        return f
    }

    func checkTarget(_ p: CGPoint) throws {
        if dry { return }
        let o = owner(at: p) ?? "?"
        if !(allowedOwners.contains(o) || o == "Deskterior?") { throw Abort(why: "a mouse-down at \(p) would land on \(o)") }
    }

    func sleep(_ s: Double) throws {
        let end = Date().addingTimeInterval(s)
        while Date() < end {
            try checkUser()
            if !dry { usleep(10_000) } else { break }
        }
    }

    func run(_ steps: [[String: Any]]) throws {
        if last == nil { last = cursor }
        for (i, step) in steps.enumerated() {
            if let note = step["note"] as? String { print("[\(i)] \(note)") }
            try checkUser()
            if let p = step["warp"] {
                let q = try point(p)
                if !dry { CGWarpMouseCursorPosition(q); CGAssociateMouseAndMouseCursorPosition(1) }
                last = q
                post(.mouseMoved, q)
            } else if let p = step["move"] {
                try glide([last ?? cursor, try point(p)], duration: step["dur"] as? Double ?? 0.4, dragging: false, flags: [])
            } else if let p = step["click"] {
                let q = try point(p)
                let f = flags(step["mods"])
                let count = step["count"] as? Int ?? 1
                if hypot(q.x - (last ?? cursor).x, q.y - (last ?? cursor).y) > 2 {
                    try glide([last ?? cursor, q], duration: step["dur"] as? Double ?? 0.35, dragging: false, flags: [])
                }
                try checkTarget(q)
                if f != [] { flagsEvent(f); heldFlags = f }
                for c in 1...count {
                    post(.leftMouseDown, q, clicks: Int64(c), flags: f); held = true
                    if !dry { usleep(60_000) }
                    post(.leftMouseUp, q, clicks: Int64(c), flags: f); held = false
                    if !dry && c < count { usleep(80_000) }
                }
                if f != [] { flagsEvent([]); heldFlags = [] }
            } else if let p = step["rclick"] {
                let q = try point(p)
                if hypot(q.x - (last ?? cursor).x, q.y - (last ?? cursor).y) > 2 {
                    try glide([last ?? cursor, q], duration: step["dur"] as? Double ?? 0.35, dragging: false, flags: [])
                }
                try checkTarget(q)
                post(.rightMouseDown, q); held = false
                if !dry { usleep(70_000) }
                post(.rightMouseUp, q)
            } else if let d = step["drag"] as? [String: Any] {
                let from = try point(d["from"])
                let to = try point(d["to"])
                let via = try ((d["via"] as? [Any]) ?? []).map { try point($0) }
                let f = flags(d["mods"])
                if hypot(from.x - (last ?? cursor).x, from.y - (last ?? cursor).y) > 2 {
                    try glide([last ?? cursor, from], duration: d["approach"] as? Double ?? 0.3, dragging: false, flags: [])
                }
                try checkTarget(from)
                // Modifiers go down before the button (⌥ over the mat shows its handles first).
                if f != [] { flagsEvent(f); heldFlags = f; try sleep(d["modLead"] as? Double ?? 0.15) }
                post(.leftMouseDown, from, flags: f)
                held = true
                try sleep(d["press"] as? Double ?? 0.12)
                // A few small moves first so the drag starts (AppKit's drag threshold).
                for k in 1...3 { post(.leftMouseDragged, CGPoint(x: from.x + Double(k), y: from.y), flags: f); if !dry { usleep(16_000) } }
                // "linear": constant speed to the release (a flick keeps its speed instead of easing out).
                try glide([last ?? from] + via + [to], duration: d["dur"] as? Double ?? 0.6, dragging: true, flags: f,
                          linear: d["linear"] as? Bool ?? false)
                try sleep(d["hold"] as? Double ?? 0.1)
                if d["keepDown"] as? Bool != true {
                    post(.leftMouseUp, to, flags: f)
                    held = false
                    // Keep the modifiers down a little past the release (a drop reads them after the mouse-up).
                    if f != [] { try sleep(d["modTrail"] as? Double ?? 0); flagsEvent([]); heldFlags = [] }
                }
            } else if let p = step["dragTo"] {
                // Continue a held drag (after keepDown) to a point, then optionally release.
                try glide([last ?? cursor, try point(p)], duration: step["dur"] as? Double ?? 0.4, dragging: true, flags: heldFlags)
                if step["release"] as? Bool == true { post(.leftMouseUp, last ?? cursor, flags: heldFlags); held = false; if heldFlags != [] { flagsEvent([]); heldFlags = [] } }
            } else if let s = step["scroll"] as? [String: Any] {
                let at = try point(s["at"])
                if hypot(at.x - (last ?? cursor).x, at.y - (last ?? cursor).y) > 2 {
                    try glide([last ?? cursor, at], duration: 0.3, dragging: false, flags: [])
                }
                let n = s["n"] as? Int ?? 10, dx = Int32(s["dx"] as? Int ?? 0), dy = Int32(s["dy"] as? Int ?? 0)
                for _ in 0..<n {
                    try checkUser()
                    if dry { print("  scroll \(dx),\(dy)") } else if let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                        e.post(tap: .cghidEventTap); usleep(16_000)
                    }
                }
            } else if let k = step["key"] as? Int {
                let f = flags(step["mods"])
                // Keys go to the focused app: refuse unless that is Deskterior (or an allowed app named in "to").
                if !dry {
                    let want = (step["to"] as? String) ?? "Deskterior"
                    let got = focusedAppName() ?? "?"
                    if got != want { throw Abort(why: "a key would go to \(got), not \(want)") }
                }
                if dry { print("  key \(k) flags \(f.rawValue)") } else {
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(k), keyDown: down)
                        e?.flags = f
                        if let chars = step["chars"] as? String {
                            let u = Array(chars.utf16)
                            e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                        }
                        e?.post(tap: .cghidEventTap)
                        usleep(40_000)
                    }
                }
            } else if let w = step["wait"] as? Double {
                try sleep(w)
            } else if let sh = step["shell"] as? String {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", sh]
                if !dry { try p.run(); p.waitUntilExit() } else { print("  shell \(sh)") }
            }
        }
    }
}

func focusedAppName() -> String? {
    // A fresh process reads the frontmost app (this one's NSWorkspace view goes stale without a run loop).
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/frontapp")
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func hideOthers(_ file: String) {
    var hidden: [String] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
        let name = app.localizedName ?? ""
        if name == "Finder" || name == "Deskterior" { continue }
        // NSRunningApplication.hide() refuses the frontmost app; the Accessibility attribute does not.
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        if app.hide() || AXUIElementSetAttributeValue(ax, kAXHiddenAttribute as CFString, kCFBooleanTrue) == .success {
            hidden.append(app.bundleIdentifier ?? "\(app.processIdentifier)")
        }
    }
    try? hidden.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
    print("hid \(hidden.count): \(hidden.joined(separator: ", "))")
}

func unhide(_ file: String) {
    let ids = (try? String(contentsOfFile: file, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    for app in NSWorkspace.shared.runningApplications where ids.contains(app.bundleIdentifier ?? "\(app.processIdentifier)") {
        if !app.unhide() {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXHiddenAttribute as CFString, kCFBooleanFalse)
        }
    }
    print("unhid \(ids.count)")
}

guard args.count >= 2 else { fail("usage: director run SCENE.json [--dry-run] [--limit s] | hide FILE | unhide FILE | windows") }
switch args[1] {
case "run":
    guard args.count >= 3, let data = FileManager.default.contents(atPath: args[2]),
          let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { fail("bad scene") }
    let dry = args.contains("--dry-run")
    var limit = 180.0
    if let i = args.firstIndex(of: "--limit"), i + 1 < args.count { limit = Double(args[i + 1]) ?? limit }
    if !dry && !AXIsProcessTrusted() { fail("Accessibility is not granted to this terminal") }
    let d = Director(dry: dry, limit: limit)
    do {
        try d.run(steps)
        d.release()
        print("done")
    } catch let a as Abort {
        d.release()
        fail("aborted: \(a.why)")
    } catch {
        d.release()
        fail("error: \(error)")
    }
case "hide": hideOthers(args[2])
case "unhide": unhide(args[2])
case "windows":
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list {
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        print("\(w[kCGWindowOwnerName as String] ?? "?")\tlayer \(w[kCGWindowLayer as String] ?? "?")\t\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))\t\(w[kCGWindowName as String] ?? "")")
    }
case "focused": print(focusedAppName() ?? "?")
default: fail("unknown command")
}
