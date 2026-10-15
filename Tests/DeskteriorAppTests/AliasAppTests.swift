import AppKit
import DeskCore
import DeskPixels
import DeskScene
import Foundation
import Metal
import Testing
@testable import DeskFiles
@testable import DeskteriorApp

extension AppTemp {
    /// A small application bundle (`Name.app` with an Info.plist and an executable).
    @discardableResult
    func app(_ path: String) throws -> URL {
        let app = try dir(path)
        let stem = app.deletingPathExtension().lastPathComponent
        let plist: [String: Any] = [
            "CFBundleIdentifier": "test.deskterior.\(stem.filter(\.isLetter))", "CFBundleName": stem,
            "CFBundleExecutable": stem, "CFBundlePackageType": "APPL",
        ]
        try dir("\(path)/Contents/MacOS")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try file("\(path)/Contents/MacOS/\(stem)", "#!/bin/sh\n")
        return app
    }
}

/// A file drag as AppKit hands one to a destination: its pasteboard, the source's operation mask (as narrowed by the
/// keys held: ⌘ to `.generic`, ⌃ to `.link`) and a sequence number.
@MainActor
private final class MockDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation
    let draggingSequenceNumber: Int

    init(_ urls: [URL], mask: NSDragOperation, sequence: Int) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("alias-test-\(UUID().uuidString)"))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
        draggingSourceOperationMask = mask
        draggingSequenceNumber = sequence
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// Erratum 29 in the app: which dropped items are apps, what a drag over the desk or a wall is told for each key, a
/// drop that aliases an app beside a document (and its undo), and the alias token: the target's icon pixelated,
/// its name without ".app", and Open, Quick Look and Show in Finder on the alias itself.
@Suite("App aliases (Erratum 29)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct AliasAppTests {
    @Test("An app is a folder of an application type or a .app package, or a link to one; a document or folder is not")
    func applications() throws {
        let temp = try AppTemp()
        let app = try temp.app("Src/Calc.app")
        let bare = try temp.dir("Src/Bare.app")
        let folder = try temp.dir("Src/Photos")
        let doc = try temp.file("Src/readme.app")
        let link = temp.root.appendingPathComponent("Src/Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        #expect(DropInController.isApplication(app))
        #expect(DropInController.isApplication(bare), "Finder shows any .app folder as an app")
        #expect(!DropInController.isApplication(folder))
        #expect(!DropInController.isApplication(doc), "a file named .app is not a bundle")
        #expect(DropInController.isApplication(link), "a link to an app is one (Safari in /Applications is a link)")
        let docLink = temp.root.appendingPathComponent("Src/Doc.app")
        try FileManager.default.createSymbolicLink(at: docLink, withDestinationURL: doc)
        #expect(!DropInController.isApplication(docLink), "a link to a document named .app is not")
        #expect(!DropInController.isApplication(temp.root.appendingPathComponent("Src/Gone.app")))
        #expect(!DropInController.isApplication(URL(string: "https://example.com/Calc.app")!))
        // An installed app, read only.
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        if FileManager.default.fileExists(atPath: calculator.path) { #expect(DropInController.isApplication(calculator)) }
        // Safari in /Applications is a system link to its own copy elsewhere: dropped with no key, it is aliased.
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        if FileManager.default.fileExists(atPath: safari.path) {
            #expect(DropInController.isApplication(safari) && DropInController.staysInstalled(safari))
            #expect(DropInController.ops([safari], copy: false, keys: nil) == [.alias])
        }
    }

    @Test("With no key, an app in a Trash or on a volume that comes and goes comes in as before; ⌘⌥ still aliases it")
    func passingApps() throws {
        let rig = try AppRig()
        let installed = try rig.temp.app("Elsewhere/Calc.app")
        let trashed = try rig.temp.app("Elsewhere/.Trash/Old.app")
        let inVolumeTrash = try rig.temp.app("Elsewhere/.Trashes/501/Older.app")
        rig.connect()
        #expect(DropInController.inTrash(trashed) && DropInController.inTrash(inVolumeTrash))
        #expect(!DropInController.inTrash(installed))
        #expect(!DropInController.inTrash(rig.temp.root.appendingPathComponent("Elsewhere/.Trash")), "the Trash itself")
        #expect(DropInController.staysInstalled(installed) && !DropInController.staysInstalled(trashed))
        // Out of a Trash with no key: moved out, as before (the source is told a move); ⌘⌥ makes an alias.
        #expect(DropInController.ops([installed, trashed, inVolumeTrash], copy: false, keys: nil) == [.alias, .move, .move])
        #expect(rig.dropIn.wallOperation([trashed], copy: false, drag: 1) == .move)
        #expect(DropInController.ops([trashed], copy: true, keys: DropKeys(mode: .alias)) == [.alias])
        // A disk image, a USB stick or a card (ejectable or removable), or a read-only volume other than the
        // system's: an alias there would break once it is gone.
        let volumes: [(ejectable: Bool, removable: Bool, readOnly: Bool, system: Bool, passing: Bool)] = [
            (false, false, false, true, false), // the system's volume (/System/Applications)
            (false, false, false, false, false), // another internal disk
            (false, false, true, true, false), // the sealed system volume
            (true, false, true, false, true), // a disk image
            (true, false, false, false, true), // a writable disk image or a USB stick
            (false, true, false, false, true), // a card
            (false, false, true, false, true), // a read-only volume
        ]
        for v in volumes {
            #expect(DropInController.passingVolume(ejectable: v.ejectable, removable: v.removable, readOnly: v.readOnly,
                                                   system: v.system) == v.passing, "\(v)")
        }
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        if FileManager.default.fileExists(atPath: calculator.path) { #expect(DropInController.staysInstalled(calculator)) }
        // The drop asks the reducer for those ops, and names the apps it read.
        var effects: [Effect] = []
        rig.store.effects = { effects.append($0) }
        #expect(rig.dropIn.dropOnWall([installed, trashed], copy: false))
        #expect(effects.contains { if case let .importFiles(_, ops, hints) = $0 {
            ops == [.alias, .move] && Set(hints.keys) == ["Calc", "Old.app"]
        } else { false } })
    }

    @Test("Over a wall: a link for an app with no key, a copy beside a document, ⌘ moves it, ⌥ copies, ⌘⌥ links all")
    func wallAnswers() throws {
        let rig = try AppRig()
        let app = try rig.temp.app("Elsewhere/Calc.app")
        let doc = try rig.temp.file("Elsewhere/notes.txt")
        rig.connect()
        let alias = DropKeys(mode: .alias), move = DropKeys(mode: .move), copy = DropKeys(mode: .copy)
        #expect(rig.dropIn.wallOperation([app], copy: false, drag: 1) == .link, "the call shape without keys")
        #expect(rig.dropIn.wallOperation([app], copy: false, drag: 1, keys: DropKeys()) == .link)
        // An alias beside a move: a copy, so a source that removes its items after a move never removes the app.
        #expect(rig.dropIn.wallOperation([app, doc], copy: false, drag: 2) == .copy, "the app stays where it is")
        #expect(DropInController.ops([app, doc], copy: false, keys: nil) == [.alias, .move])
        #expect(rig.dropIn.wallOperation([app], copy: false, drag: 3, keys: move) == .move, "⌘: an explicit move")
        #expect(rig.dropIn.wallOperation([app], copy: true, drag: 3, keys: copy) == .copy)
        #expect(rig.dropIn.wallOperation([doc], copy: true, drag: 4, keys: alias) == .link, "⌘⌥: an alias of anything")
        #expect(rig.dropIn.wallOperation([app, doc], copy: true, drag: 5, keys: alias) == .link)
        // What the source allows: no link, so the alias answers with a copy (the source keeps its item either way);
        // no answer that leaves the item where it is, so an app moves as before.
        #expect(rig.dropIn.wallOperation([app], copy: false, drag: 6, keys: DropKeys(mask: [.copy, .move])) == .copy)
        #expect(rig.dropIn.wallOperation([app], copy: false, drag: 7, keys: DropKeys(mask: [.move])) == .move)
        #expect(rig.dropIn.wallOperation([doc], copy: false, drag: 8, keys: DropKeys(mode: .move, mask: [.generic])) == .generic)
        // A volume that cannot be read still copies a document; an app becomes an alias wherever it is.
        let gone = rig.temp.root.appendingPathComponent("unreadable/b.txt")
        #expect(rig.dropIn.wallOperation([gone], copy: false, drag: 9) == .copy)
        // Every answer lies within what the source allows: under ⌘ (narrowed to .generic) a copy is the generic drop.
        let command = DropKeys(mode: .move, mask: [.generic])
        #expect(rig.dropIn.wallOperation([gone], copy: false, drag: 10, keys: command) == .generic)
        #expect(rig.dropIn.wallOperation([app, doc], copy: false, drag: 11, keys: DropKeys(mask: [.generic])) == .generic)
        // A source that allows only a link (⌃): every item becomes an alias, never a move.
        let link = DropKeys(modifiers: [.control], mask: [.link])
        #expect(link.linkOnly && !link.canMove)
        #expect(!DropInController.wantsCopy([.link], modifiers: [.control]))
        #expect(DropInController.ops([doc, app], copy: false, keys: link) == [.alias, .alias])
        #expect(rig.dropIn.wallOperation([doc], copy: false, drag: 12, keys: link) == .link)
        // A source that allows no operation we could answer with: nothing.
        #expect(rig.dropIn.wallOperation([doc], copy: false, drag: 13, keys: DropKeys(mask: [])) == [])
        #expect(rig.dropIn.wallOperation([doc], copy: false, drag: 14, keys: DropKeys(mask: [.delete])) == [])
    }

    @Test("A wall takes what the desk takes: a ⌘ drag (.generic), a ⌃ drag (.link), any key; nothing it refuses")
    func wallViewTakes() throws {
        let rig = try AppRig()
        let doc = try rig.temp.file("Elsewhere/notes.txt")
        let app = try rig.temp.app("Elsewhere/Calc.app")
        rig.connect()
        let wall = WallView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var dropped: [(urls: [URL], copy: Bool, keys: DropKeys)] = []
        wall.onDrop = { urls, copy, keys in dropped.append((urls, copy, keys)) }
        wall.operationFor = { urls, copy, drag, keys in rig.dropIn.wallOperation(urls, copy: copy, drag: drag, keys: keys) }
        #expect(wall.draggingUpdated(MockDrag([doc], mask: .every, sequence: 1)) == [], "walls take no files yet")
        #expect(!wall.performDragOperation(MockDrag([doc], mask: .every, sequence: 1)) && dropped.isEmpty)
        wall.acceptsFiles = true

        // ⌘: AppKit narrows the mask to .generic. The wall answers .generic, as the desk does, and takes the drop.
        let command = MockDrag([doc], mask: [.generic], sequence: 2)
        #expect(wall.draggingEntered(command) == .generic && wall.draggingUpdated(command) == .generic)
        #expect(wall.performDragOperation(command))
        #expect(dropped.last?.urls.map(\.lastPathComponent) == ["notes.txt"] && dropped.last?.copy == false)
        // ⌃: narrowed to .link. Taken as an alias.
        let control = MockDrag([doc], mask: [.link], sequence: 3)
        #expect(wall.draggingUpdated(control) == .link && wall.performDragOperation(control))
        #expect(dropped.last?.keys.linkOnly == true)
        // A full mask: a move for a document, a link for an app, a copy for both.
        #expect(wall.draggingUpdated(MockDrag([doc], mask: .every, sequence: 4)) == .move)
        #expect(wall.draggingUpdated(MockDrag([app], mask: .every, sequence: 5)) == .link)
        #expect(wall.draggingUpdated(MockDrag([app, doc], mask: .every, sequence: 6)) == .copy)
        // A source that allows only a copy: a copy.
        let copyOnly = MockDrag([doc], mask: [.copy], sequence: 7)
        #expect(wall.draggingUpdated(copyOnly) == .copy && wall.performDragOperation(copyOnly))
        #expect(dropped.last?.copy == true)
        // Nothing we could answer with, no files, or the desk folder not connected: refused, and nothing dropped.
        let count = dropped.count
        #expect(wall.draggingUpdated(MockDrag([doc], mask: [.delete], sequence: 8)) == [])
        #expect(!wall.performDragOperation(MockDrag([doc], mask: [.delete], sequence: 8)))
        #expect(wall.draggingUpdated(MockDrag([], mask: .every, sequence: 9)) == [])
        rig.store.replace { $0.access = .denied }
        #expect(!wall.performDragOperation(MockDrag([doc], mask: .every, sequence: 10)))
        #expect(dropped.count == count)

        // Without the desk's answer (no operationFor), the wall still takes a ⌘ drag the same way.
        wall.operationFor = nil
        #expect(wall.draggingUpdated(MockDrag([doc], mask: [.generic], sequence: 11)) == .generic)
        #expect(wall.draggingUpdated(MockDrag([doc], mask: [.link], sequence: 12)) == .link)
    }

    @Test("Over the desk: the same answers where the drop lands, nothing where it bonks")
    func deskAnswers() throws {
        let rig = try AppRig()
        let app = try rig.temp.app("Elsewhere/Calc.app")
        let doc = try rig.temp.file("Elsewhere/notes.txt")
        rig.connect()
        rig.host.scene.apply(rig.store.state)
        let screen = try #require(rig.host.scene.screen)
        let r = screen.cellRect(5, 2)
        let p = SIMD2(Float(r.midX) + 0.5, Float(r.midY) + 0.5)
        guard case .land = rig.host.scene.fileDropVerdict(count: 1, at: p) else {
            Issue.record("a monitor cell should take a drop")
            return
        }
        #expect(rig.dropIn.dragged([app], at: p, copy: false, drag: 1) == .link)
        #expect(rig.dropIn.dragged([app, doc], at: p, copy: false, drag: 2) == .copy, "the app stays where it is")
        #expect(rig.dropIn.dragged([app], at: p, copy: false, drag: 3, keys: DropKeys(mode: .move)) == .move)
        #expect(rig.dropIn.dragged([doc], at: p, copy: true, drag: 4, keys: DropKeys(mode: .alias)) == .link)
        rig.store.replace { $0.monitor.power = .off }
        rig.host.scene.apply(rig.store.state)
        #expect(rig.dropIn.dragged([app], at: p, copy: false, drag: 5) == [], "the monitor is off: a bonk")
        rig.dropIn.dragEnded()
    }

    @Test("A drop of an app beside a document: an alias of the app and the document moved in; undo takes both back")
    func dropAndUndo() async throws {
        let rig = try AppRig()
        let app = try rig.temp.app("Elsewhere/Calc.app")
        let doc = try rig.temp.file("Elsewhere/notes.txt", "n")
        let appInode = Self.inode(app)
        // A test-mode operator that may read the drop source (as a demo's), on the test's held clock.
        let scope = FileActionScope(mode: .test, folder: rig.desk, stateDirectory: rig.state,
                                    extraRoots: [app.deletingLastPathComponent()])
        let log = try OperationLog(directory: rig.state, desktop: rig.desk, mirrored: rig.desk)
        let trash = try FakeTrasher(folder: rig.fakeTrash, desktop: rig.desk, mirrored: rig.desk)
        let uptime = rig.uptime
        let files = FileActions(fileOperator: FileOperator(root: rig.desk, trasher: trash, log: log,
                                                           sandboxRoots: scope.sandboxRoots, uptime: { uptime.now }),
                                scope: scope)
        rig.effects.files = files
        var effects: [Effect] = []
        rig.store.effects = { effects.append($0); rig.effects.run($0) }
        files.dispatch = { rig.store.dispatch($0) }
        rig.connect()
        rig.uptime.hold()
        #expect(rig.dropIn.dropOnWall([app, doc], copy: false))
        #expect(effects.contains { if case let .importFiles(_, ops, _) = $0 { ops == [.alias, .move] } else { false } })
        #expect(await eventually { files.finished == 1 })
        #expect(rig.names(rig.desk) == ["Calc", "notes.txt"])
        #expect(FileManager.default.fileExists(atPath: app.path) && Self.inode(app) == appInode, "the app stayed put")
        #expect(rig.store.undoLabel == "Drop In")
        #expect(rig.host.scene.toastShown == .appAliasedRestIn)

        // The mirror sees an alias token named "Calc" where the drop put it, and the document beside it.
        let snapshot = try DesktopScanner(root: rig.desk).scan()
        rig.store.dispatch(.snapshot(snapshot, now: Date()))
        let s = rig.store.state
        let key = try #require(s.tokens.sortedKeys.first { s.tokens.meta(of: $0)?.displayName == "Calc" })
        #expect(s.tokens.meta(of: key)?.isAlias == true)
        #expect(s.tokens.location(of: key)?.isScreen == true)

        // Open, Quick Look and Show in Finder hand the alias itself to the system, which opens the app.
        let aliasURL = rig.desk.appendingPathComponent("Calc", isDirectory: false)
        effects.removeAll()
        rig.store.dispatch(.requestOpen([key]))
        rig.store.dispatch(.requestQuickLook([key]))
        rig.store.dispatch(.requestReveal([key]))
        #expect(effects == [.open([aliasURL]), .quickLook([aliasURL]), .reveal([aliasURL])])
        let target = try URL(resolvingAliasFileAt: aliasURL, options: [.withoutUI, .withoutMounting])
        #expect(DesktopLocator.canonicalPath(target) == DesktopLocator.canonicalPath(app))

        // ⌘Z: the alias goes to the (fake) Trash, the document back where it came from.
        rig.uptime.hold()
        rig.effects.withOrigin(.undo) { rig.store.dispatch(.undo) }
        #expect(await eventually { files.finished == 2 })
        #expect(rig.host.scene.toastShown == .undidAliasMix)
        #expect(rig.names(rig.desk).isEmpty && rig.names(rig.fakeTrash) == ["Calc"])
        #expect(FileManager.default.fileExists(atPath: doc.path) && Self.inode(app) == appInode)
    }

    @Test("An alias's icon is its target's real icon, pixelated, without Finder's arrow (the desk draws its own mark)")
    func aliasIcon() async throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try #require(FileManager.default.fileExists(atPath: calculator.path))
        let temp = try AppTemp()
        let desk = try temp.dir("Desk")
        let alias = desk.appendingPathComponent("Calculator", isDirectory: false)
        let bookmark = try calculator.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        let entry = try #require(try DesktopScanner(root: desk).scan().entries.first)
        #expect(entry.meta.name == "Calculator" && entry.meta.displayName == "Calculator" && entry.meta.isAlias)
        #expect(IconProvider.aliasTarget(alias).map(DesktopLocator.canonicalPath) == DesktopLocator.canonicalPath(calculator))
        #expect(IconProvider.aliasTarget(calculator) == nil, "not an alias")

        var icons: [TokenKey: IconProvider.Result] = [:]
        let provider = IconProvider(cache: nil) { key, result in icons[key] = result }
        let appKey = TokenKey(volume: "app", inode: Self.inode(calculator))
        provider.request([
            IconProvider.Request(key: entry.key, url: alias, meta: entry.meta),
            IconProvider.Request(key: appKey, url: calculator, meta: TokenMeta(name: "Calculator.app", kind: .app)),
        ])
        // The main queue is shared with the whole suite: wait as long as the other app tests do.
        #expect(await eventually { icons.count == 2 })
        guard case let .pixels(aliasIcon, aliasMini)? = icons[entry.key], case let .pixels(appIcon, appMini)? = icons[appKey]
        else {
            Issue.record("no pixels: \(icons)")
            return
        }
        var opaque = 0
        for y in 0..<16 { for x in 0..<16 where aliasIcon[x, y].a > 0 { opaque += 1 } }
        #expect(opaque > 80, "a real icon, not an empty one")
        #expect(aliasIcon == appIcon && aliasMini == appMini, "the app's own icon, pixel for pixel")

        // A broken alias (its target gone) still gets the alias file's own workspace icon.
        let gone = try temp.app("Src/Gone.app")
        let broken = desk.appendingPathComponent("Gone", isDirectory: false)
        try URL.writeBookmarkData(try gone.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil,
                                                        relativeTo: nil), to: broken)
        try FileManager.default.removeItem(at: gone)
        #expect(IconProvider.aliasTarget(broken) == nil)
    }

    static func inode(_ url: URL) -> UInt64 {
        var st = stat()
        return lstat(url.path, &st) == 0 ? UInt64(st.st_ino) : 0
    }
}
