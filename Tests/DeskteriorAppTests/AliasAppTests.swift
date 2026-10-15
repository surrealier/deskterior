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

/// Erratum 29 in the app: which dropped items are apps, what a drag over the desk or a wall is told for each key, a
/// drop that aliases an app beside a document (and its undo), and the alias token: the target's icon pixelated,
/// its name without ".app", and Open, Quick Look and Show in Finder on the alias itself.
@Suite("App aliases (Erratum 29)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct AliasAppTests {
    @Test("An app is a folder of an application type or a .app package; a document, a folder or a link is not")
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
        #expect(!DropInController.isApplication(link), "a link to an app moves as the link")
        #expect(!DropInController.isApplication(temp.root.appendingPathComponent("Src/Gone.app")))
        #expect(!DropInController.isApplication(URL(string: "https://example.com/Calc.app")!))
        // An installed app, read only.
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        if FileManager.default.fileExists(atPath: calculator.path) { #expect(DropInController.isApplication(calculator)) }
    }

    @Test("Over a wall: a link for an app with no key, a move beside a document, ⌘ moves it, ⌥ copies, ⌘⌥ links all")
    func wallAnswers() throws {
        let rig = try AppRig()
        let app = try rig.temp.app("Elsewhere/Calc.app")
        let doc = try rig.temp.file("Elsewhere/notes.txt")
        rig.connect()
        let alias = DropKeys(mode: .alias), move = DropKeys(mode: .move), copy = DropKeys(mode: .copy)
        #expect(rig.dropIn.wallOperation([app], copy: false, drag: 1) == .link, "the call shape without keys")
        #expect(rig.dropIn.wallOperation([app], copy: false, drag: 1, keys: DropKeys()) == .link)
        #expect(rig.dropIn.wallOperation([app, doc], copy: false, drag: 2) == .move, "an alias beside a move: a move")
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
        #expect(rig.dropIn.dragged([app, doc], at: p, copy: false, drag: 2) == .move)
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
