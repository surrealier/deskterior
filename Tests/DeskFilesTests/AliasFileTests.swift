import DeskCore
import Foundation
import Testing
@testable import DeskFiles

/// Clears every lock under `url` (and the folder itself), so TempDesk can remove it.
private func unlockAll(_ url: URL) {
    _ = lchflags(url.path, 0)
    chmod(url.path, 0o755)
    let e = FileManager.default.enumerator(atPath: url.path)
    while let rel = e?.nextObject() as? String {
        let p = url.appendingPathComponent(rel).path
        _ = lchflags(p, 0)
        var st = stat()
        if lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { chmod(p, 0o755) }
    }
}

/// Everything about an item that a change to it would show: every file and folder in it (as a relative path) with
/// its inode, size, flags, modification and status-change times and extended attributes.
private struct Fingerprint: Equatable {
    struct Item: Equatable {
        var path: String
        var inode: UInt64
        var size: Int64
        var flags: UInt32
        var mtime: timespec
        var ctime: timespec
        var xattrs: [String: Data]

        static func == (a: Item, b: Item) -> Bool {
            a.path == b.path && a.inode == b.inode && a.size == b.size && a.flags == b.flags
                && a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
                && a.ctime.tv_sec == b.ctime.tv_sec && a.ctime.tv_nsec == b.ctime.tv_nsec && a.xattrs == b.xattrs
        }
    }

    var items: [Item]

    init(_ url: URL) {
        var paths = [""]
        if let e = FileManager.default.enumerator(atPath: url.path) {
            while let rel = e.nextObject() as? String { paths.append(rel) }
        }
        items = paths.sorted().compactMap { rel -> Item? in
            let p = rel.isEmpty ? url.path : url.appendingPathComponent(rel).path
            var st = stat()
            guard lstat(p, &st) == 0 else { return nil }
            return Item(path: rel, inode: UInt64(st.st_ino), size: Int64(st.st_size), flags: st.st_flags,
                        mtime: st.st_mtimespec, ctime: st.st_ctimespec, xattrs: Self.xattrs(p))
        }
    }

    static func xattrs(_ path: String) -> [String: Data] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return [:] }
        var out: [String: Data] = [:]
        for name in names.split(separator: 0).map({ String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }) {
            let n = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard n >= 0 else { continue }
            var buf = [UInt8](repeating: 0, count: n)
            _ = getxattr(path, name, &buf, n, 0, XATTR_NOFOLLOW)
            out[name] = Data(buf)
        }
        return out
    }
}

extension FileRig {
    /// A small application bundle (`Name.app` with an Info.plist and an executable), as Finder and Launch Services
    /// see one: a package of type `com.apple.application-bundle`.
    @discardableResult
    func app(_ dir: URL, _ name: String) throws -> URL {
        let app = dir.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let stem = (name as NSString).deletingPathExtension
        let plist: [String: Any] = [
            "CFBundleIdentifier": "test.deskterior.\(stem.filter(\.isLetter))", "CFBundleName": stem,
            "CFBundleExecutable": stem, "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/\(stem)"))
        return app
    }

    /// The item the alias file at `url` points to (resolved without UI or mounting), realpath'd.
    func target(ofAlias url: URL) -> String? {
        guard let resolved = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) else { return nil }
        return DesktopLocator.canonicalPath(resolved)
    }

    func isAliasFile(_ url: URL) -> Bool {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
    }
}

/// Erratum 29: an application dropped onto the desk becomes a Finder alias (as does anything with ⌘⌥). The operator
/// writes the alias in its staging place and renames it into place with `RENAME_EXCL` (" 2" on a clash, like a
/// copy), checks identities as for a copy, never touches the source, and its undo trashes only the alias.
@Suite("FileOperator aliases (Erratum 29)")
struct AliasFileTests {
    // MARK: Making one

    @Test("An app becomes a Finder alias named without .app; the app itself is untouched (inode, times, xattrs)")
    func appAlias() async throws {
        let rig = try FileRig()
        let app = try rig.app(rig.elsewhere, "Calc.app")
        #expect(setxattr(app.path, "com.example.note", "kept", 4, 0, XATTR_NOFOLLOW) == 0)
        let before = Fingerprint(app)
        let result = await rig.op.importItems([app], ops: [.alias], rig.intent(.drop))
        let alias = rig.at(rig.desk, "Calc")
        #expect(result.outcomes == [.aliased(app, to: alias)])
        #expect(result.undo != nil)
        #expect(rig.names(rig.desk) == ["Calc"], "the alias only; no staging folder left behind")
        #expect(rig.isAliasFile(alias))
        #expect(rig.target(ofAlias: alias) == DesktopLocator.canonicalPath(app), "it opens the app")
        #expect(Fingerprint(app) == before, "the app is never touched")
        #expect(rig.log.entries().map(\.op) == [.importAlias])
        #expect(rig.log.entries().map(\.names) == [["Calc.app", "Calc"]])

        // What the model hears: an alias placed under its own name, "Make Alias", and that the app stayed put.
        let report = FileReport(import: result, undo: FileUndoRef(1), ops: [.alias])
        #expect(report.placed == [FileReport.Placed(source: app.standardizedFileURL.path, name: "Calc", key: rig.key(alias),
                                                    aliased: true)])
        #expect(report.undoLabel == "Make Alias" && report.toast == .aliasMade && report.problems.isEmpty)

        // The mirror sees an alias token named "Calc".
        let snapshot = try DesktopScanner(root: rig.desk).scan()
        #expect(snapshot.entries.map(\.meta.name) == ["Calc"])
        #expect(snapshot.entries.first?.meta.isAlias == true)
        #expect(snapshot.entries.first?.key == rig.key(alias))
    }

    @Test("A folder or a document keeps its full name; ⌘⌥ (op .alias) of any item leaves the original in place")
    func otherAliases() async throws {
        let rig = try FileRig()
        let doc = try rig.file(rig.elsewhere, "report.pdf", "pages")
        let folder = try rig.temp.mkdir("Elsewhere/Photos.2026")
        try rig.file(folder, "a.jpg")
        let dotted = try rig.app(rig.elsewhere, "Foo.Bar.app")
        let before = [Fingerprint(doc), Fingerprint(folder), Fingerprint(dotted)]
        let result = await rig.op.importItems([doc, folder, dotted], ops: [.alias, .alias, .alias], rig.intent(.drop))
        #expect(result.outcomes == [
            .aliased(doc, to: rig.at(rig.desk, "report.pdf")), .aliased(folder, to: rig.at(rig.desk, "Photos.2026")),
            .aliased(dotted, to: rig.at(rig.desk, "Foo.Bar")),
        ])
        #expect([Fingerprint(doc), Fingerprint(folder), Fingerprint(dotted)] == before)
        #expect(rig.text(doc) == "pages" && rig.names(folder) == ["a.jpg"])
        #expect(rig.target(ofAlias: rig.at(rig.desk, "Photos.2026")) == DesktopLocator.canonicalPath(folder))
        let report = FileReport(import: result, undo: nil, ops: [.alias, .alias, .alias])
        #expect(report.toast == .aliasesMadeOriginals && report.undoLabel == "Make Alias")
    }

    @Test("A taken name gets \" 2\", \" 3\"… exactly like a copy, and the item already there is untouched")
    func clashes() async throws {
        let rig = try FileRig()
        let mine = try rig.file(rig.desk, "Calc", "mine")
        try rig.file(rig.desk, "report.pdf", "mine too")
        try rig.temp.mkdir("Desk/Photos.2026")
        try rig.temp.mkdir("Desk/Foo.Bar")
        let app = try rig.app(rig.elsewhere, "Calc.app")
        let doc = try rig.file(rig.elsewhere, "report.pdf")
        let folder = try rig.temp.mkdir("Elsewhere/Photos.2026")
        let dotted = try rig.app(rig.elsewhere, "Foo.Bar.app")
        let inode = rig.inode(mine)
        var result = await rig.op.importItems([app, doc, folder, dotted], ops: Array(repeating: .alias, count: 4),
                                              rig.intent(.drop))
        #expect(result.outcomes == [
            .renamed(app, to: rig.at(rig.desk, "Calc 2"), op: .alias),
            .renamed(doc, to: rig.at(rig.desk, "report 2.pdf"), op: .alias),
            .renamed(folder, to: rig.at(rig.desk, "Photos.2026 2"), op: .alias),
            .renamed(dotted, to: rig.at(rig.desk, "Foo.Bar 2"), op: .alias),
        ])
        result = await rig.op.importItems([app], ops: [.alias], rig.intent(.drop))
        #expect(result.outcomes == [.renamed(app, to: rig.at(rig.desk, "Calc 3"), op: .alias)])
        #expect(rig.text(mine) == "mine" && rig.inode(mine) == inode)
        #expect(rig.log.entries().last?.outcome == "renamed")
        let report = FileReport(import: result, undo: nil, ops: [.alias])
        #expect(report.placed.map(\.name) == ["Calc 3"] && report.toast == .aliasMade)
    }

    @Test("A name planted between the check and the rename is never replaced: the alias lands as \" 2\"")
    func plantedDestination() async throws {
        let rig = try FileRig()
        let app = try rig.app(rig.elsewhere, "Calc.app")
        let planted = rig.at(rig.desk, "Calc")
        let once = Once()
        await rig.op.setHooks(.init(beforeRename: { destination in
            once { try? Data("planted".utf8).write(to: destination) }
        }))
        let result = await rig.op.importItems([app], ops: [.alias], rig.intent(.drop))
        #expect(result.outcomes == [.renamed(app, to: rig.at(rig.desk, "Calc 2"), op: .alias)])
        #expect(rig.text(planted) == "planted")
    }

    @Test("An app on another volume is aliased all the same, never copied")
    func crossVolume() async throws {
        let rig = try FileRig(volumeID: { url in url.path.contains("/Elsewhere") ? "OTHER-VOLUME" : "DESK-VOLUME" })
        let app = try rig.app(rig.elsewhere, "Calc.app")
        let result = await rig.op.importItems([app], ops: [.alias], rig.intent(.drop))
        #expect(result.outcomes == [.aliased(app, to: rig.at(rig.desk, "Calc"))])
        #expect(rig.isAliasFile(rig.at(rig.desk, "Calc")))
    }

    @Test("A drop of an app beside a document aliases the app and moves the document, item by item")
    func mixedDrop() async throws {
        let rig = try FileRig()
        let app = try rig.app(rig.elsewhere, "Calc.app")
        let doc = try rig.file(rig.elsewhere, "notes.txt", "n")
        let before = Fingerprint(app)
        let result = await rig.op.importItems([app, doc], ops: [.alias, .move], rig.intent(.drop))
        #expect(result.outcomes == [.aliased(app, to: rig.at(rig.desk, "Calc")), .moved(doc, to: rig.at(rig.desk, "notes.txt"))])
        #expect(Fingerprint(app) == before && !rig.exists(doc))
        #expect(rig.log.entries().map(\.op) == [.importAlias, .importMove])
        let report = FileReport(import: result, undo: nil, ops: [.alias, .move])
        #expect(report.toast == .appAliasedRestIn && report.undoLabel == "Drop In")

        // Undo: the alias goes to the Trash, the document goes back; the app is still never touched.
        let record = try #require(result.undo)
        let undone = await rig.op.undo(record, rig.intent(.undo))
        #expect(undone.refusals.isEmpty)
        #expect(rig.names(rig.desk).isEmpty && rig.exists(doc) && Fingerprint(app) == before)
        #expect(FileReport(undo: undone, of: .importItems, record: record).toast == .undidAliasMix)
        #expect(rig.log.entries().suffix(2).map(\.op) == [.moveBack, .trashAlias])
    }

    @Test("A mismatched op list is refused whole; a cancelled drop makes no alias")
    func mismatched() async throws {
        let rig = try FileRig()
        let app = try rig.app(rig.elsewhere, "Calc.app")
        let result = await rig.op.importItems([app], ops: [.alias, .alias], rig.intent(.drop))
        #expect(result.outcomes == [.refused(app, .mismatchedRequest)])
        #expect(rig.names(rig.desk).isEmpty)
        #expect(await rig.op.importItems([app], ops: [.alias], rig.intent(.menuItem)).refusals == [.wrongOrigin])
        #expect(rig.names(rig.desk).isEmpty)
    }

    // MARK: Undo

    @Test("Undo trashes the alias after its identity check and never touches the app; plural toasts")
    func undo() async throws {
        let rig = try FileRig()
        let a = try rig.app(rig.elsewhere, "Calc.app")
        let b = try rig.app(rig.elsewhere, "Notes.app")
        let before = [Fingerprint(a), Fingerprint(b)]
        let one = await rig.op.importItems([a], ops: [.alias], rig.intent(.drop))
        let record = try #require(one.undo)
        let undone = await rig.op.undo(record, rig.intent(.undo))
        #expect(undone.outcomes.count == 1 && undone.refusals.isEmpty)
        #expect(rig.names(rig.desk).isEmpty)
        #expect(rig.trashNames == ["Calc"], "the alias is in the trash, not the app")
        #expect(FileReport(undo: undone, of: .importItems, record: record).toast == .undidAlias)
        #expect([Fingerprint(a), Fingerprint(b)] == before)
        #expect(rig.log.entries().last?.op == .trashAlias)

        let two = await rig.op.importItems([a, b], ops: [.alias, .alias], rig.intent(.drop))
        let report = FileReport(import: two, undo: nil, ops: [.alias, .alias])
        #expect(report.toast == .aliasesMade)
        let record2 = try #require(two.undo)
        let undone2 = await rig.op.undo(record2, rig.intent(.undo))
        #expect(FileReport(undo: undone2, of: .importItems, record: record2).toast == .undidAliases)
        #expect([Fingerprint(a), Fingerprint(b)] == before)
        // Without its record the report cannot tell an alias from a copy (as before Erratum 29).
        #expect(FileReport(undo: undone2, of: .importItems).toast == .undidCopyIn)
    }

    @Test("Undo refuses an alias that was replaced meanwhile and leaves what is there alone")
    func undoReplaced() async throws {
        let rig = try FileRig()
        let app = try rig.app(rig.elsewhere, "Calc.app")
        let result = await rig.op.importItems([app], ops: [.alias], rig.intent(.drop))
        let alias = rig.at(rig.desk, "Calc")
        #expect(rename(alias.path, rig.at(rig.elsewhere, "old alias").path) == 0)
        try Data("someone else's".utf8).write(to: alias)
        let undone = await rig.op.undo(try #require(result.undo), rig.intent(.undo))
        #expect(undone.refusals == [.identityChanged])
        #expect(rig.text(alias) == "someone else's" && rig.trashNames.isEmpty)
    }

    // MARK: Identity

    @Test("An item swapped in for the source while the alias is written is refused, and nothing lands")
    func sourceSwapped() async throws {
        let rig = try FileRig()
        let app = try rig.app(rig.elsewhere, "Calc.app")
        let aside = rig.at(rig.elsewhere, "Aside.app")
        let once = Once()
        await rig.op.setHooks(.init(afterCopy: { _ in
            once {
                _ = rename(app.path, aside.path)
                try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
            }
        }))
        let result = await rig.op.importItems([app], ops: [.alias], rig.intent(.drop))
        #expect(result.outcomes == [.refused(app, .identityChanged)])
        #expect(result.undo == nil)
        #expect(rig.names(rig.desk).isEmpty, "no alias, no staging folder")
    }

    @Test("An item swapped in right after the alias's final rename is left alone; the alias has no undo step")
    func swappedAfterPlace() async throws {
        let rig = try FileRig()
        let app = try rig.app(rig.elsewhere, "Calc.app")
        let aside = rig.at(rig.elsewhere, "moved-away")
        await rig.op.setHooks(.init(afterPlace: { placed in
            _ = rename(placed.path, aside.path)
            try? Data("theirs".utf8).write(to: placed)
        }))
        let result = await rig.op.importItems([app], ops: [.alias], rig.intent(.drop))
        #expect(result.outcomes == [.refused(app, .landedUnverified)])
        #expect(result.undo == nil)
        #expect(rig.text(rig.at(rig.desk, "Calc")) == "theirs")
        let report = FileReport(import: result, undo: nil, ops: [.alias])
        #expect(report.problems == [.aliasUnverified] && report.toast == .aliasNoUndo)
        // The same refusal of a copy still says "Copied in" (the problem follows the op asked for).
        #expect(FileReport(import: result, undo: nil, ops: [.copy]).toast == .copiedNoUndo)
    }

    // MARK: Refusals

    @Test("Into a locked desk folder nothing lands (macOS refuses); the app is untouched")
    func lockedDesk() async throws {
        let rig = try FileRig()
        let app = try rig.app(rig.elsewhere, "Calc.app")
        let before = Fingerprint(app)
        defer { unlockAll(rig.temp.root) }
        #expect(lchflags(rig.desk.path, UInt32(UF_IMMUTABLE)) == 0)
        let result = await rig.op.importItems([app], ops: [.alias], rig.intent(.drop))
        #expect(result.refusals == [.notPermitted])
        #expect(result.undo == nil)
        #expect(rig.names(rig.desk).isEmpty)
        #expect(Fingerprint(app) == before)
        #expect(FileReport(import: result, undo: nil, ops: [.alias]).toast == .fileNotPermitted)
    }

    @Test("A locked app, or one in a locked folder, is aliased: unlike a move, nothing of it changes")
    func lockedSource() async throws {
        let rig = try FileRig()
        let folder = try rig.temp.mkdir("Elsewhere/Locked")
        let inLocked = try rig.app(folder, "Calc.app")
        let locked = try rig.app(rig.elsewhere, "Notes.app")
        defer { unlockAll(rig.temp.root) }
        #expect(lchflags(folder.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(lchflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        let before = [Fingerprint(inLocked), Fingerprint(locked)]
        let result = await rig.op.importItems([inLocked, locked], ops: [.alias, .alias], rig.intent(.drop))
        #expect(result.outcomes == [.aliased(inLocked, to: rig.at(rig.desk, "Calc")), .aliased(locked, to: rig.at(rig.desk, "Notes"))])
        #expect([Fingerprint(inLocked), Fingerprint(locked)] == before)
        // The same drop as a move is refused as locked (Errata 25).
        let moved = await rig.op.importItems([inLocked], ops: [.move], rig.intent(.drop))
        #expect(moved.refusals == [.locked])
    }

    @Test("Missing items, the desk folder, a folder holding it and items outside the sandbox are refused")
    func refusals() async throws {
        let rig = try FileRig()
        let gone = rig.at(rig.elsewhere, "Gone.app")
        let other = try TempDesk()
        let foreign = try rig.app(other.root, "Foreign.app")
        let onDesk = try rig.file(rig.desk, "a.txt")
        let result = await rig.op.importItems([gone, rig.desk, rig.temp.root, foreign, onDesk],
                                              ops: Array(repeating: .alias, count: 5), rig.intent(.drop))
        #expect(result.outcomes == [
            .refused(gone, .missing), .refused(rig.desk, .containsDesktop), .refused(rig.temp.root, .containsDesktop),
            .refused(foreign, .outsideSandbox), .unchanged(onDesk),
        ])
        #expect(result.undo == nil)
        #expect(rig.names(rig.desk) == ["a.txt"])
        let report = FileReport(import: result, undo: nil, ops: Array(repeating: .alias, count: 5))
        #expect(report.placed.isEmpty && report.toast == .someGone, "the item already on the desk counts as done")
    }

    @Test("Aliases beside refusals say some stayed; a move that came in as a copy is still said first")
    func batchToasts() {
        let app = URL(fileURLWithPath: "/src/Calc.app"), doc = URL(fileURLWithPath: "/src/a.txt")
        let desk = URL(fileURLWithPath: "/desk")
        let some = FileResult(outcomes: [.aliased(app, to: desk.appendingPathComponent("Calc")), .refused(doc, .missing)], undo: nil)
        #expect(FileReport(import: some, undo: nil, ops: [.alias, .move], identity: { _ in nil }).toast == .someGone)
        let copied = FileResult(outcomes: [
            .aliased(app, to: desk.appendingPathComponent("Calc")), .copied(doc, to: desk.appendingPathComponent("a.txt")),
        ], undo: nil)
        let report = FileReport(import: copied, undo: nil, ops: [.alias, .move], identity: { _ in nil })
        #expect(report.toast == .copiedInstead && report.undoLabel == "Drop In")
        let asked = FileReport(import: copied, undo: nil, ops: [.alias, .copy], identity: { _ in nil })
        #expect(asked.toast == .appAliasedRestIn)
        let apps = FileResult(outcomes: [
            .aliased(app, to: desk.appendingPathComponent("Calc")),
            .renamed(URL(fileURLWithPath: "/src/Notes.app"), to: desk.appendingPathComponent("Notes 2"), op: .alias),
            .moved(doc, to: desk.appendingPathComponent("a.txt")),
        ], undo: nil)
        #expect(FileReport(import: apps, undo: nil, ops: [.alias, .alias, .move], identity: { _ in nil }).toast == .appsAliasedRestIn)
        let one = FileResult(outcomes: [.aliased(doc, to: desk.appendingPathComponent("a.txt"))], undo: nil)
        #expect(FileReport(import: one, undo: nil, ops: [.alias], identity: { _ in nil }).toast == .aliasMadeOriginal)
    }
}
