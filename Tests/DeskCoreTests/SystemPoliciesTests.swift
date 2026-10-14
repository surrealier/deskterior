import Foundation
import Testing
@testable import DeskCore

/// The opt-in system hooks with fakes (M12): the hotkey and the login item are registered only from a setting the
/// user turned on; App Translocation; widget frames → avoid rects.
@Suite("System policies")
struct SystemPoliciesTests {
    final class FakeHotKeys: HotKeyRegistrar {
        var calls: [String] = []
        var accept = true

        func registerHotKey(_ binding: HotKeyBinding) -> Bool {
            calls.append("register \(binding.keyCode) \(binding.modifiers)")
            return accept
        }

        func unregisterHotKey() { calls.append("unregister") }
    }

    final class FakeLoginItem: LoginItemService, @unchecked Sendable {
        var status: LoginItemStatus
        var calls: [String] = []
        var failRegister = false

        init(_ status: LoginItemStatus = .notRegistered) {
            self.status = status
        }

        func register() throws {
            calls.append("register")
            if failRegister { throw CocoaError(.featureUnsupported) }
            status = .enabled
        }

        func unregister() throws {
            calls.append("unregister")
            status = .notRegistered
        }
    }

    @Test("The Peek hotkey is ⌃⌥⌘D and is registered only while its setting is on")
    func hotkey() {
        let b = HotKeyBinding.peekDesk
        #expect(b.keyCode == 2 && b.modifiers == HotKeyBinding.control | HotKeyBinding.option | HotKeyBinding.command)
        let fake = FakeHotKeys()
        var p = HotKeyPolicy()
        let r1 = p.apply(enabled: false, with: fake)
        #expect(!r1)
        #expect(fake.calls.isEmpty, "off by default: nothing is registered")
        let r2 = p.apply(enabled: true, with: fake)
        #expect(r2)
        let r3 = p.apply(enabled: true, with: fake)
        #expect(r3)
        #expect(fake.calls == ["register 2 6400"], "once")
        let r4 = p.apply(enabled: false, with: fake)
        #expect(!r4)
        #expect(fake.calls == ["register 2 6400", "unregister"])
        // Another app holds the combination: registration fails and is tried again next time.
        let busy = FakeHotKeys()
        busy.accept = false
        var q = HotKeyPolicy()
        let r5 = q.apply(enabled: true, with: busy)
        #expect(!r5)
        let r6 = q.apply(enabled: false, with: busy)
        #expect(!r6 && busy.calls == ["register 2 6400"])
    }

    @Test("Launch at Login off: the service is never touched, at launch or otherwise")
    func loginOff() {
        let fake = FakeLoginItem()
        var s = DeskSettings()
        let r7 = LoginItemPolicy.launch(&s, version: "0.1.0", service: fake)
        #expect(r7 == .unchanged)
        #expect(fake.calls.isEmpty && s == DeskSettings())
    }

    @Test("Turning it on registers and remembers the version; turning it off unregisters")
    func loginToggle() {
        let fake = FakeLoginItem()
        var s = DeskSettings()
        let r8 = LoginItemPolicy.set(true, &s, version: "0.1.0 7", service: fake)
        #expect(r8 == .added)
        #expect(fake.calls == ["register"] && s.launchAtLogin && s.loginItemVersion == "0.1.0 7")
        let r9 = LoginItemPolicy.set(false, &s, version: "0.1.0 7", service: fake)
        #expect(r9 == .removed)
        #expect(fake.calls == ["register", "unregister"] && !s.launchAtLogin && s.loginItemVersion == nil)
        // Off while not registered: nothing to call.
        let r10 = LoginItemPolicy.set(false, &s, version: "0.1.0 7", service: fake)
        #expect(r10 == .removed)
        #expect(fake.calls.count == 2)
    }

    @Test("At launch: re-registered after an update only when opted in; a removal elsewhere turns the setting off")
    func loginLaunch() {
        let fake = FakeLoginItem(.enabled)
        var s = DeskSettings()
        s.launchAtLogin = true
        s.loginItemVersion = "0.1.0 7"
        let r11 = LoginItemPolicy.launch(&s, version: "0.1.0 7", service: fake)
        #expect(r11 == .unchanged)
        #expect(fake.calls.isEmpty)
        let r12 = LoginItemPolicy.launch(&s, version: "0.2.0 9", service: fake)
        #expect(r12 == .added)
        #expect(fake.calls == ["register"] && s.loginItemVersion == "0.2.0 9")
        // The user removed it in System Settings ▸ Login Items: respect that.
        let removed = FakeLoginItem(.notRegistered)
        var t = s
        let r13 = LoginItemPolicy.launch(&t, version: "0.2.0 9", service: removed)
        #expect(r13 == .turnedOffElsewhere)
        #expect(removed.calls.isEmpty && !t.launchAtLogin && t.loginItemVersion == nil)
        // Waiting for approval.
        let pending = FakeLoginItem(.requiresApproval)
        var u = s
        let r14 = LoginItemPolicy.launch(&u, version: "0.2.0 9", service: pending)
        #expect(r14 == .needsApproval)
        #expect(pending.calls.isEmpty && u.launchAtLogin)
    }

    @Test("A failed registration is reported and turns the setting off (the toggle never claims a missing item)")
    func loginFailure() {
        let fake = FakeLoginItem()
        fake.failRegister = true
        var s = DeskSettings()
        let r15 = LoginItemPolicy.set(true, &s, version: "1", service: fake)
        #expect(r15 == .failed)
        #expect(!s.launchAtLogin && s.loginItemVersion == nil)
        // At launch after an update, too: the next launch does not try again.
        var t = DeskSettings()
        t.launchAtLogin = true
        t.loginItemVersion = "0"
        let r16 = LoginItemPolicy.launch(&t, version: "1", service: fake)
        #expect(r16 == .failed && !t.launchAtLogin && t.loginItemVersion == nil)
        let again = LoginItemPolicy.launch(&t, version: "1", service: fake)
        #expect(again == .unchanged && fake.calls == ["register", "register"])
    }

    @Test("Settings shows what is registered: the toggle follows an item added or removed outside the app")
    func loginReconcile() {
        var s = DeskSettings()
        #expect(!LoginItemPolicy.reconcile(&s, status: .notRegistered, version: "2"))
        #expect(s == DeskSettings())
        #expect(LoginItemPolicy.reconcile(&s, status: .enabled, version: "2"))
        #expect(s.launchAtLogin && s.loginItemVersion == "2")
        #expect(!LoginItemPolicy.reconcile(&s, status: .requiresApproval, version: "2"), "still registered")
        #expect(LoginItemPolicy.reconcile(&s, status: .notFound, version: "2"))
        #expect(!s.launchAtLogin && s.loginItemVersion == nil)
    }

    @Test("A translocated copy never registers at launch (it would record a temporary path)")
    func loginTranslocated() {
        let fake = FakeLoginItem()
        var s = DeskSettings()
        s.launchAtLogin = true
        s.loginItemVersion = "1"
        let r = LoginItemPolicy.launch(&s, version: "2", service: fake, translocated: true)
        #expect(r == .unchanged && fake.calls.isEmpty && s.launchAtLogin && s.loginItemVersion == "1")
    }

    @Test("While peeking, the app's windows sit just above the floating desk; otherwise at the normal level")
    func peekLevels() {
        let normal = 0, floating = 3
        #expect(PeekPolicy.appWindowLevel(peeking: true, deskLevel: floating, normal: normal) == floating + 1)
        #expect(PeekPolicy.appWindowLevel(peeking: false, deskLevel: floating, normal: normal) == normal)
        // --windowed: the desk is an ordinary window, and so are the others.
        #expect(PeekPolicy.appWindowLevel(peeking: true, deskLevel: normal, normal: normal) == normal)
    }

    @Test("A drop from another app: move, copy with ⌥ or when only copying is offered, nothing when neither is")
    func dropOps() {
        #expect(ImportOp.forDrop(copyHeld: false, canMove: true, canCopy: true) == .move)
        #expect(ImportOp.forDrop(copyHeld: true, canMove: true, canCopy: true) == .copy)
        #expect(ImportOp.forDrop(copyHeld: false, canMove: false, canCopy: true) == .copy)
        #expect(ImportOp.forDrop(copyHeld: true, canMove: true, canCopy: false) == nil)
        #expect(ImportOp.forDrop(copyHeld: false, canMove: false, canCopy: false) == nil)
    }

    @Test("App Translocation: a randomized read-only path; the note shows once")
    func translocation() {
        let moved = "/private/var/folders/xy/T/AppTranslocation/4F1C-UUID/d/Deskterior.app"
        #expect(Translocation.isTranslocated(bundlePath: moved))
        #expect(!Translocation.isTranslocated(bundlePath: "/Applications/Deskterior.app"))
        var s = DeskSettings()
        #expect(Translocation.shouldShowNote(bundlePath: moved, settings: s))
        s.translocationNoteShown = true
        #expect(!Translocation.shouldShowNote(bundlePath: moved, settings: s))
    }

    @Test("Widgets: the widget host's windows below normal windows become canvas rects on the desk's display")
    func widgets() {
        let host: Int32 = 501
        let windows = [
            WidgetGeometry.Window(pid: host, layer: -2_147_483_601, bounds: PointRect(x: 8, y: 45, width: 180, height: 180)),
            WidgetGeometry.Window(pid: host, layer: -2_147_483_601, bounds: PointRect(x: 188, y: 45, width: 180, height: 180)),
            // A notification banner (far above) and someone else's window.
            WidgetGeometry.Window(pid: host, layer: 23, bounds: PointRect(x: 1100, y: 40, width: 360, height: 80)),
            WidgetGeometry.Window(pid: 77, layer: -2_147_483_601, bounds: PointRect(x: 600, y: 300, width: 200, height: 200)),
            // A tiny helper window.
            WidgetGeometry.Window(pid: host, layer: -2_147_483_601, bounds: PointRect(x: 0, y: 0, width: 1, height: 1)),
        ]
        let found = WidgetGeometry.widgets(windows, widgetPIDs: [host])
        #expect(found.count == 2)
        let grid = PixelGrid(display: DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2, topInsetPt: 33))
        let screen = WidgetGeometry.topLeft(PointRect(x: 0, y: 0, width: 1470, height: 956), primaryHeight: 956)
        #expect(screen == PointRect(x: 0, y: 0, width: 1470, height: 956))
        let rects = WidgetGeometry.avoidRects(found, screenTopLeft: screen, grid: grid)
        #expect(rects.count == 2)
        // 2.5 pt per art px at S 5: 180 pt is 72 art px; the rect covers every art pixel the widget touches.
        let a = rects[0]
        #expect(a.w >= 72 && a.w <= 74 && a.h >= 72 && a.h <= 74)
        let p = grid.artPoint(fromViewPoint: SIMD2(8, 45))
        #expect(a.origin == p)
        // A display to the left of the menu-bar display (global x < 0) sees nothing of these widgets.
        let other = WidgetGeometry.topLeft(PointRect(x: -1920, y: 0, width: 1920, height: 1080), primaryHeight: 956)
        #expect(WidgetGeometry.avoidRects(found, screenTopLeft: other, grid: grid).isEmpty)
    }
}
