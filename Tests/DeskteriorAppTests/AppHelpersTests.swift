import AppKit
import DeskCore
import DeskFiles
import Foundation
import SwiftUI
import Testing
@testable import DeskteriorApp

@Suite("Empty Wastebasket's sheet")
struct EmptyBasketSheetTests {
    @Test("The question counts the items; the details list the names, then \"and N more\", then what it means")
    func text() {
        #expect(EmptyBasketSheet.message(count: 1) == "Move the item in the wastebasket to the Trash?")
        #expect(EmptyBasketSheet.message(count: 25) == "Move the 25 items in the wastebasket to the Trash?")
        let details = EmptyBasketSheet.details(names: ["a.txt", "보고서.pdf"], more: 3).components(separatedBy: "\n")
        #expect(details.prefix(4) == ["• a.txt", "• 보고서.pdf", "and 3 more", ""])
        #expect(details.last?.hasPrefix("The wastebasket only hides files on the desk.") == true)
        #expect(!EmptyBasketSheet.details(names: ["a.txt"], more: 0).contains("more"))
    }

    @Test("Escape and ⌘. cancel; Return and other keys do not (Return is Cancel's own key)")
    func cancelKeys() {
        #expect(EmptyBasketSheet.isCancelKey(keyCode: 53, characters: "\u{1b}", command: false))
        #expect(EmptyBasketSheet.isCancelKey(keyCode: 47, characters: ".", command: true))
        #expect(!EmptyBasketSheet.isCancelKey(keyCode: 47, characters: ".", command: false))
        #expect(!EmptyBasketSheet.isCancelKey(keyCode: 36, characters: "\r", command: false))
        #expect(!EmptyBasketSheet.isCancelKey(keyCode: 12, characters: "q", command: true))
    }

    @Test("Cancel is the first, default button (Return); Move to Trash is second, destructive, with no key")
    func buttons() {
        _ = NSApplication.shared
        let alert = EmptyBasketSheet.alert(.emptyWastebasket(names: ["a.txt"], more: 0), count: 1)
        #expect(alert.buttons.map(\.title) == ["Cancel", "Move to Trash"])
        #expect(alert.buttons[0].keyEquivalent == "\r" && !alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[1].keyEquivalent.isEmpty && alert.buttons[1].hasDestructiveAction)
        #expect(alert.messageText == "Move the item in the wastebasket to the Trash?")
        #expect(alert.alertStyle == .warning)
    }
}

@Suite("Drop-in and drag-out rules in the app")
struct DropRuleTests {
    @Test("A drop copies with ⌥, or when the source offers copying but neither move nor generic")
    func wantsCopy() {
        #expect(DropInController.wantsCopy([.copy], modifiers: []))
        #expect(!DropInController.wantsCopy([.copy, .move], modifiers: []))
        #expect(!DropInController.wantsCopy([.copy, .generic], modifiers: []))
        #expect(DropInController.wantsCopy([.copy, .move], modifiers: .option))
        #expect(!DropInController.wantsCopy([], modifiers: []))
        #expect(!DropInController.wantsCopy([.link], modifiers: []))
    }

    @Test("An item whose folder is the desk folder by any spelling is spelled under the model's root")
    func spelled() throws {
        let temp = try AppTemp()
        let desk = try temp.dir("Desk")
        let link = temp.root.appendingPathComponent("DeskLink")
        #expect(symlink(desk.path, link.path) == 0)
        let viaLink = link.appendingPathComponent("a.txt")
        #expect(DropInController.spelled(viaLink, underRoot: desk.path).path == desk.appendingPathComponent("a.txt").path)
        let upper = URL(fileURLWithPath: desk.path.uppercased()).appendingPathComponent("b.txt")
        #expect(DropInController.spelled(upper, underRoot: desk.path).path == desk.appendingPathComponent("b.txt").path)
        let outside = temp.root.appendingPathComponent("Other/c.txt")
        #expect(DropInController.spelled(outside, underRoot: desk.path) == outside.standardizedFileURL)
    }

    @Test("Items on the desk's volume are moved; one whose volume cannot be read (or another volume) is copied")
    func crossesVolumes() throws {
        let temp = try AppTemp()
        let desk = try temp.dir("Desk")
        let a = try temp.file("Elsewhere/a.txt")
        #expect(!DropInController.crossesVolumes([a], desk: desk))
        #expect(DropInController.crossesVolumes([a, temp.root.appendingPathComponent("gone.txt")], desk: desk))
        #expect(DropInController.crossesVolumes([a], desk: temp.root.appendingPathComponent("no-desk")))
    }

    @Test("Drag-out offers every operation Finder does, or only copying with \"Always copy\"")
    func dragOutMask() {
        #expect(DragOutController.mask(DragOutRule.offered(alwaysCopy: false)) == [.copy, .move, .link, .generic, .delete])
        #expect(DragOutController.mask(DragOutRule.offered(alwaysCopy: true)) == .copy)
    }

    @Test("How a drag out ended decides the rest: only exactly .delete over the Dock trashes, after a wait")
    func dragOutEndings() {
        func outcome(_ op: NSDragOperation, dock: Bool) -> DragOutRule.Outcome {
            DragOutRule.outcome(DragOutController.outcomes(op), overDock: dock)
        }
        #expect(outcome(.delete, dock: true) == .delete)
        #expect(outcome(.delete, dock: false) == .move, "a delete from anything but the Dock only waits")
        #expect(outcome([.copy, .delete], dock: true) == .copy, "several bits: the least consequential")
        #expect(outcome([.move, .generic], dock: false) == .generic)
        #expect(outcome([], dock: true) == .none)
        #expect(DragOutRule.plan(.delete) == .waitForRemoval(seconds: 1.5, thenTrash: true))
        #expect(DragOutRule.plan(.move) == .waitForRemoval(seconds: 5, thenTrash: false))
        #expect(DragOutRule.plan(.copy) == .returnHome && DragOutRule.plan(.none) == .returnHome)
        let k = TokenKey(volume: "v", inode: 1)
        #expect(DragOutRule.toTrash(.waitForRemoval(seconds: 1.5, thenTrash: true), stillThere: [k]) == [k])
        #expect(DragOutRule.toTrash(.waitForRemoval(seconds: 1.5, thenTrash: true), stillThere: [k], finderTookOver: true)
            .isEmpty)
        #expect(DragOutRule.toTrash(.waitForRemoval(seconds: 5, thenTrash: false), stillThere: [k]).isEmpty)
        #expect(!DragOutController.isDockWindow(0) && !DragOutController.isDockWindow(-1))
    }
}

@Suite("Settings, window levels and the single-instance guard")
struct AppPolicyTests {
    @Test("Only desk mode keeps settings in the app's defaults; development runs keep them in memory, in English")
    func settingsDomain() throws {
        #expect(SettingsStore.persists(try LaunchOptions.parse([])))
        for args in [["--windowed"], ["--headless"], ["--demo", "x.json"], ["--windowed", "--language", "ko"]] {
            let o = try LaunchOptions.parse(args)
            #expect(!SettingsStore.persists(o))
            let store = SettingsStore.forLaunch(o)
            #expect(!store.isPersistent)
            #expect(store.settings.language == (o.language ?? .en))
        }
        #expect(DeskSettings.suiteName(bundleIdentifier: nil, fallback: AppIdentity.fallbackBundleID)
            == AppIdentity.fallbackBundleID)
        #expect(DeskSettings.suiteName(bundleIdentifier: "io.github.someone.deskterior", fallback: AppIdentity.fallbackBundleID)
            == nil, "inside the .app: the app's own domain (a suite named after it is refused)")
    }

    @Test("A memory store migrates old spellings, tells observers each change, and writes nowhere else")
    func memoryStore() {
        let store = SettingsStore(memory: ["lights": "lampOnly", "reduceMotion": true])
        #expect(store.settings.lights == .lampOnly && store.settings.reduceMotion == .on)
        var seen: [(DeskSettings, DeskSettings)] = []
        store.observe { seen.append(($0, $1)) }
        store.update { $0.peekHotkeyEnabled = true }
        store.update { $0.peekHotkeyEnabled = true }
        #expect(seen.count == 1 && seen[0].0.peekHotkeyEnabled && !seen[0].1.peekHotkeyEnabled)
        #expect(!store.isPersistent)
    }

    @Test("Desk windows sit one (or three) levels above the desktop icons; the app's windows rise above a peek")
    func levels() {
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        #expect(DeskWindow.windowLevel(.iconPlus1).rawValue == icons + 1)
        #expect(DeskWindow.windowLevel(.iconPlus3).rawValue == icons + 3)
        #expect(DeskWindow.windowLevel(.normal) == .normal)
        let normal = NSWindow.Level.normal.rawValue, floating = NSWindow.Level.floating.rawValue
        #expect(PeekPolicy.appWindowLevel(peeking: true, deskLevel: floating, normal: normal) == floating + 1)
        #expect(PeekPolicy.appWindowLevel(peeking: false, deskLevel: floating, normal: normal) == normal)
        #expect(PeekPolicy.appWindowLevel(peeking: true, deskLevel: normal, normal: normal) == normal, "--windowed")
        #expect(PeekPolicy.appWindowLevel(peeking: true, deskLevel: icons + 1, normal: normal) == normal)
    }

    @Test("Peek lifts the app's titled windows (never shown here) and puts them back")
    func appWindowLevels() {
        _ = NSApplication.shared
        let window = AppWindow.make(title: "Test", view: Text("x"))
        defer { window.close() }
        let raised = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        AppWindow.setLevel(raised)
        #expect(AppWindow.level == raised && window.level == raised && !window.isVisible)
        AppWindow.setLevel(.normal)
        #expect(AppWindow.level == .normal && window.level == .normal)
    }

    @Test("Another process with our bundle id (or, unbundled, our executable) is a duplicate; we are not")
    func singleInstance() throws {
        typealias R = AppIdentity.RunningApp
        let id = "io.github.someone.deskterior"
        #expect(AppIdentity.isDuplicate(me: 10, bundleID: id, executable: nil,
                                        running: [R(pid: 10, bundleID: id), R(pid: 11, bundleID: id)]))
        #expect(!AppIdentity.isDuplicate(me: 10, bundleID: id, executable: nil, running: [R(pid: 10, bundleID: id)]))
        #expect(!AppIdentity.isDuplicate(me: 10, bundleID: id, executable: nil, running: [R(pid: 11, bundleID: "x.y")]))
        let temp = try AppTemp()
        let exe = try temp.file("bin/Deskterior")
        let link = temp.root.appendingPathComponent("Deskterior-link")
        #expect(symlink(exe.path, link.path) == 0)
        let other = try temp.file("bin/Other")
        #expect(AppIdentity.isDuplicate(me: 10, bundleID: nil, executable: link,
                                        running: [R(pid: 10, executable: link), R(pid: 12, executable: exe)]))
        #expect(!AppIdentity.isDuplicate(me: 10, bundleID: nil, executable: exe, running: [R(pid: 12, executable: other)]))
        #expect(!AppIdentity.isDuplicate(me: 10, bundleID: nil, executable: nil, running: [R(pid: 12, executable: exe)]))
        #expect(!AppIdentity.isDuplicate(me: 10, bundleID: nil, executable: exe, running: [R(pid: 12)]))
        #expect(AppIdentity.checksForDuplicates(try LaunchOptions.parse([])))
        #expect(!AppIdentity.checksForDuplicates(try LaunchOptions.parse(["--windowed"])))
        #expect(!AppIdentity.checksForDuplicates(try LaunchOptions.parse(["--headless"])))
    }
}
