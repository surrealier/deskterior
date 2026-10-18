import DeskCore
import Foundation
import Testing
@testable import DeskFiles

/// Save as Text File on Desktop (Erratum 31): the one file `FileOperator` writes. A new file only, staged and renamed
/// in with `RENAME_EXCL`, from a menu item's intent; undone by moving it to the trash only while it is exactly as
/// written. Everything happens inside a `TempDesk` with the FakeTrash; the real desktop is never touched.
@Suite("FileOperator: Save as Text File")
struct FileOperatorCreateTests {
    static let text = Data("우유 사기\n".utf8)

    func create(_ rig: FileRig, _ name: String = "우유 사기.txt", _ contents: Data = Self.text,
                _ intent: ExplicitIntent? = nil) async -> FileResult {
        await rig.op.createTextFile(named: name, contents: contents, intent ?? rig.intent(.menuItem))
    }

    /// The record's one step.
    func step(_ result: FileResult) -> FileUndoRecord.Step? { result.undo?.steps.first }

    func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    // MARK: Creating

    @Test("A new file in the desk folder only, with exactly the text asked for; logged create-file")
    func createsInRoot() async throws {
        let rig = try FileRig()
        let result = await create(rig)
        let url = rig.at(rig.desk, "우유 사기.txt")
        #expect(result.outcomes == [.created(url, renamed: false)])
        #expect(bytes(url) == Self.text && rig.names(rig.desk) == ["우유 사기.txt"])
        #expect(rig.names(rig.elsewhere).isEmpty && rig.trashNames.isEmpty)
        #expect(Set(rig.names(rig.state)).isSubset(of: ["FakeTrash", "operations.log"]))
        var st = stat()
        #expect(lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && st.st_nlink == 1)
        #expect(st.st_mode & 0o600 == 0o600 && st.st_mode & 0o133 == 0, "an ordinary document, at most rw-r--r--")
        let record = try #require(result.undo)
        #expect(record.kind == .createTextFile)
        guard case let .trashCreated(u, key, size, _)? = step(result) else {
            Issue.record("expected a trashCreated step, got \(String(describing: step(result)))")
            return
        }
        #expect(u == url && key == rig.key(url) && size == Int64(Self.text.count))
        let line = try #require(rig.log.entries().last)
        #expect(line.op == .createFile && line.origin == .menuItem && line.outcome == "ok")
        #expect(line.names == ["우유 사기.txt"] && line.inodes == [rig.inode(url)])
    }

    @Test("A taken name lands as \"name 2\"; the file there keeps its bytes and inode")
    func clash() async throws {
        let rig = try FileRig()
        let mine = try rig.file(rig.desk, "Memo.txt", "the user's own")
        let inode = rig.inode(mine)
        let result = await create(rig, "Memo.txt")
        let second = rig.at(rig.desk, "Memo 2.txt")
        #expect(result.outcomes == [.created(second, renamed: true)])
        #expect(rig.text(mine) == "the user's own" && rig.inode(mine) == inode)
        #expect(bytes(second) == Self.text)
        let third = await create(rig, "Memo.txt")
        #expect(third.outcomes == [.created(rig.at(rig.desk, "Memo 3.txt"), renamed: true)])
        #expect(rig.names(rig.desk) == ["Memo 2.txt", "Memo 3.txt", "Memo.txt"])
        let line = try #require(rig.log.entries().last)
        #expect(line.op == .createFile && line.names == ["Memo.txt", "Memo 3.txt"] && line.outcome == "renamed")
        // A folder, a symlink (to a file elsewhere) and a dangling symlink take names too: never written through.
        let target = try rig.file(rig.elsewhere, "target.txt", "keep me")
        try FileManager.default.createDirectory(at: rig.at(rig.desk, "Folder.txt"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: rig.at(rig.desk, "Link.txt"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: rig.at(rig.desk, "Dangling.txt"),
                                                   withDestinationURL: rig.at(rig.elsewhere, "nothing.txt"))
        for name in ["Folder.txt", "Link.txt", "Dangling.txt"] {
            let r = await create(rig, name)
            let stem = String(name.dropLast(4))
            #expect(r.outcomes == [.created(rig.at(rig.desk, "\(stem) 2.txt"), renamed: true)], "\(name)")
        }
        #expect(rig.text(target) == "keep me" && !rig.exists(rig.at(rig.elsewhere, "nothing.txt")))
        #expect(rig.names(rig.at(rig.desk, "Folder.txt")).isEmpty)
    }

    @Test("Names clash as the desk's volume compares them: by case and Unicode form where it folds them")
    func foldedClash() async throws {
        let rig = try FileRig()
        let values = try rig.desk.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        try rig.file(rig.desk, "memo.txt", "lower")
        try rig.file(rig.desk, "Cafe\u{301}.txt", "decomposed")
        let upper = await create(rig, "MEMO.txt")
        let composed = await create(rig, "Café.txt")
        if values.volumeSupportsCaseSensitiveNames == false {
            #expect(upper.outcomes.first?.destination?.lastPathComponent == "MEMO 2.txt")
        }
        // APFS and HFS+ never hold two names that differ only in Unicode form.
        #expect(composed.outcomes.first?.destination?.lastPathComponent.precomposedStringWithCanonicalMapping
            == "Café 2.txt")
        #expect(rig.text(rig.at(rig.desk, "memo.txt")) == "lower")
        #expect(rig.text(rig.at(rig.desk, "Cafe\u{301}.txt")) == "decomposed")
    }

    @Test("A file planted at the name between the choice and the rename is never written over")
    func plantedDestination() async throws {
        let rig = try FileRig()
        let once = Once()
        await rig.op.setHooks(.init(beforeRename: { destination in
            once { try? Data("planted".utf8).write(to: destination) }
        }))
        let result = await create(rig, "a.txt")
        #expect(result.outcomes == [.created(rig.at(rig.desk, "a 2.txt"), renamed: true)])
        #expect(rig.text(rig.at(rig.desk, "a.txt")) == "planted" && bytes(rig.at(rig.desk, "a 2.txt")) == Self.text)
    }

    @Test("With every free name taken at the last moment nothing is written over and nothing is left behind")
    func plantedEverywhere() async throws {
        let rig = try FileRig()
        await rig.op.setHooks(.init(beforeRename: { destination in
            try? Data("planted".utf8).write(to: destination)
        }))
        let result = await create(rig, "a.txt")
        #expect(result.outcomes == [.refused(rig.at(rig.desk, "a.txt"), .noFreeName)] && result.undo == nil)
        let names = rig.names(rig.desk)
        #expect(names.count == 100 && names.allSatisfy { rig.text(rig.at(rig.desk, $0)) == "planted" })
        #expect(rig.log.entries().last?.outcome == "refused: no-free-name")
    }

    @Test("No partial file is ever on the desk: the text is written in a staging folder and renamed in whole")
    func noPartialFile() async throws {
        for inDesk in [false, true] {
            let rig = try FileRig()
            let desk = rig.desk
            let seen = Seen()
            await rig.op.setHooks(.init(
                beforeRename: { _ in seen.add(Self.names(desk)) }, afterCopy: { staged in
                    seen.add(Self.names(desk))
                    seen.staged(staged, bytes: (try? Data(contentsOf: staged)) ?? Data())
                }, stageInDesk: inDesk
            ))
            let big = Data(String(repeating: "가나다라마바사\n", count: 2000).utf8)
            let result = await create(rig, "big.txt", big)
            #expect(result.refusals.isEmpty)
            #expect(!seen.lists.isEmpty)
            for list in seen.lists {
                #expect(!list.contains("big.txt"), "inDesk \(inDesk): \(list)")
                #expect(list.allSatisfy { $0.hasPrefix(FileMoves.partialPrefix) } == true, "inDesk \(inDesk): \(list)")
                #expect(inDesk || list.isEmpty, "the system's staging folder lies outside the desk")
            }
            #expect(seen.stagedBytes == big, "the staged file was whole before it was renamed in")
            #expect(seen.stagedURL.map { DesktopLocator.isInsideDesktop($0, desktop: desk) } == inDesk)
            #expect(rig.names(desk) == ["big.txt"] && bytes(rig.at(desk, "big.txt")) == big, "and the staging went")
            #expect(PartialCopies.find(in: desk).isEmpty)
        }
    }

    @Test("Two saves at once of one name both land, under two names")
    func concurrent() async throws {
        let rig = try FileRig()
        async let a = create(rig, "same.txt", Data("A\n".utf8))
        async let b = create(rig, "same.txt", Data("B\n".utf8))
        let (ra, rb) = await (a, b)
        let landed = Set([ra, rb].compactMap { $0.outcomes.first?.destination?.lastPathComponent })
        #expect(landed == ["same.txt", "same 2.txt"])
        #expect(Set(["same.txt", "same 2.txt"].compactMap { rig.text(rig.at(rig.desk, $0)) }) == ["A\n", "B\n"])
    }

    @Test("A copy swapped in right after the rename is left alone, with no undo step")
    func landedUnverified() async throws {
        let rig = try FileRig()
        let desk = rig.desk
        await rig.op.setHooks(.init(afterPlace: { placed in
            let swap = desk.appendingPathComponent(".swap")
            try? Data("someone else's".utf8).write(to: swap)
            _ = rename(swap.path, placed.path)
        }))
        let result = await create(rig, "a.txt")
        #expect(result.outcomes == [.refused(rig.at(desk, "a.txt"), .landedUnverified)] && result.undo == nil)
        #expect(rig.text(rig.at(desk, "a.txt")) == "someone else's")
    }

    @Test("A desk folder that cannot be written refuses, and nothing is left anywhere")
    func readOnlyDesk() async throws {
        for inDesk in [false, true] {
            let rig = try FileRig()
            await rig.op.setHooks(.init(stageInDesk: inDesk))
            #expect(chmod(rig.desk.path, 0o555) == 0)
            defer { chmod(rig.desk.path, 0o755) }
            let result = await create(rig, "a.txt")
            #expect(result.refusals == [.notPermitted], "inDesk \(inDesk)")
            #expect(result.undo == nil && rig.names(rig.desk).isEmpty)
        }
    }

    // MARK: Refusals

    @Test("Only a fresh menu-item intent writes: stale, spent, forged and every other origin are refused")
    func intents() async throws {
        let rig = try FileRig()
        let stale = await create(rig, "a.txt", Self.text, rig.intent(.menuItem, age: 11))
        #expect(stale.refusals == [.staleIntent])
        let once = rig.intent(.menuItem)
        let first = await create(rig, "b.txt", Self.text, once)
        let again = await create(rig, "c.txt", Self.text, once)
        #expect(first.refusals.isEmpty && again.refusals == [.spentIntent])
        for origin in ExplicitIntent.Origin.allCases where origin != .menuItem {
            let r = await create(rig, "d.txt", Self.text, rig.intent(origin))
            #expect(r.refusals == [.wrongOrigin] && r.undo == nil, "\(origin)")
        }
        #expect(FileOperator.Method.createFile.origins == [.menuItem])
        #expect(rig.names(rig.desk) == ["b.txt"])
        let refusedLines = rig.log.entries().filter { $0.op == .createFile && $0.outcome.hasPrefix("refused") }
        #expect(refusedLines.count == 7 && refusedLines.allSatisfy { $0.inodes.isEmpty })
    }

    @Test("Names that are not plain, visible .txt names are refused before anything is written", arguments: [
        "", ".", "..", "a/b.txt", "../a.txt", "/a.txt", ".hidden.txt", ".txt", "notes.md", "notes.TXT", "notes.txt.",
        "a:b.txt", "a\nb.txt", "a\u{0}b.txt", "\u{202E}txt.exe.txt", "zero\u{200B}width.txt", "a/\u{301}b.txt",
        ".\u{301}x.txt", "x.tx\u{301}t", String(repeating: "가", count: 84) + ".txt",
    ])
    func names(name: String) async throws {
        let rig = try FileRig()
        let result = await rig.op.createTextFile(named: name, contents: Self.text, rig.intent(.menuItem))
        #expect(result.refusals == [.invalidName] && result.undo == nil, "\(name.debugDescription)")
        #expect(rig.names(rig.desk).isEmpty && rig.names(rig.temp.root) == ["Desk", "Elsewhere", "State"])
        #expect(rig.log.entries().last?.names == [name] && rig.log.entries().last?.outcome == "refused: invalid-name")
    }

    @Test("Text past 64 KB, or not UTF-8, is refused; a name of exactly 255 bytes is fine")
    func contents() async throws {
        let rig = try FileRig()
        let tooBig = await create(rig, "big.txt", Data(repeating: UInt8(ascii: "a"), count: FileOperator.maxTextFileBytes + 1))
        #expect(tooBig.refusals == [.invalidContents])
        let notText = await create(rig, "bad.txt", Data([0x61, 0xFF, 0xFE, 0x0A]))
        #expect(notText.refusals == [.invalidContents])
        #expect(rig.names(rig.desk).isEmpty)
        let edge = await create(rig, "edge.txt", Data(repeating: UInt8(ascii: "a"), count: FileOperator.maxTextFileBytes))
        #expect(edge.refusals.isEmpty)
        let long = String(repeating: "가", count: 83) + "ab.txt" // 249 + 6 = 255 bytes
        #expect(long.utf8.count == 255)
        let named = await create(rig, long)
        #expect(named.refusals.isEmpty && rig.exists(rig.at(rig.desk, long)))
        // Its clash still fits: "가…가 2.txt" is shortened to 255 bytes (NFC; a URL spells it decomposed).
        let clash = await create(rig, long)
        let second = clash.outcomes.first?.destination?.lastPathComponent.precomposedStringWithCanonicalMapping
        #expect(clash.refusals.isEmpty && second == String(repeating: "가", count: 83) + " 2.txt")
    }

    @Test("Outside the sandbox nothing is written")
    func sandbox() async throws {
        let rig = try FileRig()
        let narrow = rig.makeOperator(sandboxRoots: [rig.elsewhere])
        let result = await narrow.createTextFile(named: "a.txt", contents: Self.text, rig.intent(.menuItem))
        #expect(result.refusals == [.outsideSandbox] && rig.names(rig.desk).isEmpty)
    }

    // MARK: Undo

    @Test("Undo moves the very file to the trash (never deletes it), once; logged trash-created")
    func undo() async throws {
        let rig = try FileRig()
        let result = await create(rig)
        let url = rig.at(rig.desk, "우유 사기.txt")
        let inode = rig.inode(url)
        let record = try #require(result.undo)
        let undone = await rig.op.undo(record, rig.intent(.undo))
        let trashed = rig.at(rig.trasher.folder, "우유 사기.txt")
        #expect(undone.outcomes == [.trashed(url, to: trashed)])
        #expect(!rig.exists(url) && rig.inode(trashed) == inode && bytes(trashed) == Self.text)
        let line = try #require(rig.log.entries().last)
        #expect(line.op == .trashCreated && line.origin == .undo && line.outcome == "ok" && line.inodes == [inode])
        let again = await rig.op.undo(record, rig.intent(.undo))
        #expect(again.refusals == [.unknownRecord] && rig.inode(trashed) == inode)
        // Only an undo intent replays it; a refused intent keeps the record.
        let other = await create(rig, "other.txt")
        let menu = await rig.op.undo(try #require(other.undo), rig.intent(.menuItem))
        #expect(menu.refusals == [.wrongOrigin] && rig.exists(rig.at(rig.desk, "other.txt")))
        let later = await rig.op.undo(try #require(other.undo), rig.intent(.undo))
        #expect(later.refusals.isEmpty && !rig.exists(rig.at(rig.desk, "other.txt")))
    }

    @Test("Undo leaves a file the user changed: more text, the same length rewritten, a new date, or swapped",
          arguments: ["append", "rewrite", "touch", "swap", "gone", "renamed"])
    func undoRefusesChanged(change: String) async throws {
        let rig = try FileRig()
        let result = await create(rig, "note.txt", Data("abc\n".utf8))
        let url = rig.at(rig.desk, "note.txt")
        let record = try #require(result.undo)
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        switch change {
        case "append":
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            try h.write(contentsOf: Data("more\n".utf8))
            try h.close()
        case "rewrite":
            // The same size; its modification date moves on.
            try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(-60)], ofItemAtPath: url.path)
            try Data("xyz\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(5)], ofItemAtPath: url.path)
        case "touch":
            try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(1)], ofItemAtPath: url.path)
        case "swap":
            // An editor's safe-save: the same text, a new inode.
            let swap = try rig.file(rig.desk, ".swap", "abc\n")
            #expect(rename(swap.path, url.path) == 0)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        case "gone":
            try FileManager.default.moveItem(at: url, to: rig.at(rig.elsewhere, "note.txt"))
        default:
            try FileManager.default.moveItem(at: url, to: rig.at(rig.desk, "renamed.txt"))
        }
        let kept = rig.names(rig.desk)
        let undone = await rig.op.undo(record, rig.intent(.undo))
        let expected: FileRefusal = ["gone", "renamed"].contains(change) ? .missing : .identityChanged
        #expect(undone.outcomes == [.refused(url, expected)], "\(change)")
        #expect(rig.trashNames.isEmpty && rig.names(rig.desk) == kept)
        #expect(rig.log.entries().last?.op == .trashCreated)
        #expect(FileReport(undo: undone, of: .createTextFile).toast == (expected == .missing ? .fileGone : .fileChanged))
    }

    @Test("A file edited between the check and the trash comes straight back, and the undo is refused")
    func undoEditRace() async throws {
        let rig = try FileRig()
        let result = await create(rig, "note.txt")
        let url = rig.at(rig.desk, "note.txt")
        let once = Once()
        await rig.op.setHooks(.init(beforeTrash: { item in
            once {
                guard let h = try? FileHandle(forWritingTo: item) else { return }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data("typed just now\n".utf8))
                try? h.close()
            }
        }))
        let undone = await rig.op.undo(try #require(result.undo), rig.intent(.undo))
        #expect(undone.refusals == [.identityChanged])
        #expect(rig.trashNames.isEmpty && rig.text(url)?.hasSuffix("typed just now\n") == true)
    }

    @Test("Undo refuses a file swapped right before its check")
    func undoSwapAtCheck() async throws {
        let rig = try FileRig()
        let result = await create(rig, "note.txt", Data("abc\n".utf8))
        let desk = rig.desk
        await rig.op.setHooks(.init(beforeCheck: { url in
            guard url.lastPathComponent == "note.txt" else { return }
            let swap = desk.appendingPathComponent(".swap")
            try? Data("abc\n".utf8).write(to: swap)
            _ = rename(swap.path, url.path)
        }))
        let undone = await rig.op.undo(try #require(result.undo), rig.intent(.undo))
        #expect(undone.refusals == [.identityChanged] && rig.trashNames.isEmpty)
    }

    // MARK: Helpers

    static func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }
}

/// What a hook saw, from the operator's threads.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var _lists: [[String]] = []
    private var _bytes: Data?
    private var _url: URL?

    func add(_ list: [String]) { lock.withLock { _lists.append(list) } }

    func staged(_ url: URL, bytes: Data) {
        lock.withLock {
            _url = url
            _bytes = bytes
        }
    }

    var lists: [[String]] { lock.withLock { _lists } }
    var stagedBytes: Data? { lock.withLock { _bytes } }
    var stagedURL: URL? { lock.withLock { _url } }
}
