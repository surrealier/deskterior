import DeskCore
import Foundation
import Testing
@testable import DeskFiles

/// A clock that moves only when told: wall time for log lines, monotonic time for intent freshness.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let start = ContinuousClock.now
    private var offset: Duration = .zero

    var now: Date { lock.withLock { date.addingTimeInterval(Self.seconds(offset)) } }
    var instant: ContinuousClock.Instant { lock.withLock { start + offset } }

    func advance(_ seconds: Double) { lock.withLock { offset += .seconds(seconds) } }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// Runs a closure once, the first time it is asked to.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func callAsFunction(_ body: () -> Void) {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}

/// A fake desk (`Desk`), a folder to drop from (`Elsewhere`) and a state folder (`State`: the log and the
/// FakeTrash), all inside one `TempDesk`, which is also the operator's only sandbox root. The real desktop and
/// the real Trash are never involved.
final class FileRig: @unchecked Sendable {
    let temp: TempDesk
    let desk: URL
    let elsewhere: URL
    let state: URL
    let clock = TestClock()
    let log: OperationLog
    let trasher: FakeTrasher
    let op: FileOperator

    init(volumeID: (@Sendable (URL) -> String?)? = nil) throws {
        temp = try TempDesk()
        // Realpath'd (/var is /private/var), so expected URLs match the operator's.
        func real(_ u: URL) -> URL { URL(fileURLWithPath: DesktopLocator.canonicalPath(u), isDirectory: true) }
        desk = real(try temp.mkdir("Desk"))
        elsewhere = real(try temp.mkdir("Elsewhere"))
        state = real(try temp.mkdir("State"))
        log = try OperationLog(directory: state, desktop: desk, mirrored: desk)
        trasher = try FakeTrasher(folder: state.appendingPathComponent("FakeTrash"), desktop: desk, mirrored: desk)
        let clock = clock
        op = FileOperator(
            root: desk, trasher: trasher, log: log, sandboxRoots: [temp.root], clock: { clock.now },
            uptime: { clock.instant }, volumeID: volumeID ?? FileOperator.volumeUUID
        )
    }

    /// Another operator on this rig's log and clock.
    func makeOperator(
        root: URL? = nil, trasher: (any Trasher)? = nil, sandboxRoots: [URL]? = nil
    ) -> FileOperator {
        FileOperator(
            root: root ?? desk, trasher: trasher ?? self.trasher, log: log, sandboxRoots: sandboxRoots ?? [temp.root],
            clock: { [clock] in clock.now }, uptime: { [clock] in clock.instant }
        )
    }

    /// `dir/name` spelled as the operator spells results (no trailing slash for folders).
    func at(_ dir: URL, _ name: String) -> URL { dir.appendingPathComponent(name, isDirectory: false) }

    /// A freshly issued intent, `age` seconds old by this rig's clock.
    func intent(_ origin: ExplicitIntent.Origin = .menuItem, age: Double = 0) -> ExplicitIntent {
        ExplicitIntent(origin: origin, issuedAt: clock.now.addingTimeInterval(-age), instant: clock.instant - .seconds(age))
    }

    @discardableResult
    func file(_ dir: URL, _ name: String, _ text: String = "x") throws -> URL {
        let u = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: u)
        return u
    }

    /// A `.rtfd` package (a folder Finder shows as one document).
    @discardableResult
    func package(_ dir: URL, _ name: String) throws -> URL {
        let u = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try Data("{\\rtf1 hello}".utf8).write(to: u.appendingPathComponent("TXT.rtf"))
        try Data([1, 2, 3]).write(to: u.appendingPathComponent("image.png"))
        return u
    }

    func key(_ url: URL) -> TokenKey {
        var st = stat()
        let inode = lstat(url.path, &st) == 0 ? UInt64(st.st_ino) : 0
        return TokenKey(volume: FileOperator.volumeUUID(url) ?? FileOperator.volumeUUID(desk) ?? "unknown", inode: inode)
    }

    func inode(_ url: URL) -> UInt64 { key(url).inode }

    func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// Names in `dir` (NFC, sorted), hidden ones included.
    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .map(\.precomposedStringWithCanonicalMapping).sorted()
    }

    var trashNames: [String] { names(trasher.folder) }
}

private func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

@Suite("FileOperator")
struct FileOperatorTests {
    // MARK: Collisions

    @Test("Finder-style numbered names keep the last extension apart for files and packages only")
    func numberedNames() {
        func second(_ name: String, splits: Bool = true) -> String { FileMoves.candidates(for: name, splitsExtension: splits)[1] }
        #expect(second("report.pdf") == "report 2.pdf")
        #expect(second("Notes.rtfd") == "Notes 2.rtfd")
        #expect(second("Folder", splits: false) == "Folder 2")
        #expect(second("v1.2", splits: false) == "v1.2 2")
        #expect(second("archive.tar.gz") == "archive.tar 2.gz")
        #expect(second(".hidden") == ".hidden 2")
        #expect(second("trailing.") == "trailing. 2")
        #expect(second("my file.final draft") == "my file.final draft 2")
        #expect(second("report 2.pdf") == "report 3.pdf")
        #expect(second("Room 101") == "Room 102")
        #expect(second("Agent 007") == "Agent 007 2")
        let all = FileMoves.candidates(for: "a.txt", splitsExtension: true)
        #expect(all.count == 100)
        #expect(all.first == "a.txt")
        #expect(all.last == "a 100.txt")
        let long = String(repeating: "가", count: 84) + ".txt" // 252 + 4 bytes
        #expect(FileMoves.candidates(for: long, splitsExtension: true).dropFirst().allSatisfy { $0.utf8.count <= 255 })
    }

    @Test("A drop onto a taken name lands as \"name 2\", then \"name 3\"; the existing file is untouched")
    func collisionTwo() async throws {
        let rig = try FileRig()
        let existing = try rig.file(rig.desk, "report.pdf", "mine")
        let a = try rig.file(rig.elsewhere, "report.pdf", "dropped A")
        var result = await rig.op.importItems([a], op: .move, rig.intent(.drop))
        let second = rig.at(rig.desk, "report 2.pdf")
        #expect(result.outcomes == [.renamed(a, to: second, op: .move)])
        #expect(rig.text(existing) == "mine")
        #expect(rig.text(second) == "dropped A")
        #expect(!rig.exists(a))

        let b = try rig.file(rig.elsewhere, "report.pdf", "dropped B")
        result = await rig.op.importItems([b], op: .copy, rig.intent(.drop))
        let third = rig.at(rig.desk, "report 3.pdf")
        #expect(result.outcomes == [.renamed(b, to: third, op: .copy)])
        #expect(rig.text(third) == "dropped B")
        #expect(rig.text(b) == "dropped B")
        #expect(rig.names(rig.desk) == ["report 2.pdf", "report 3.pdf", "report.pdf"])

        try FileManager.default.createDirectory(at: rig.at(rig.desk, "Folder"), withIntermediateDirectories: false)
        let folder = try rig.temp.mkdir("Elsewhere/Folder")
        try rig.file(folder, "inside.txt")
        result = await rig.op.importItems([folder], op: .move, rig.intent(.drop))
        #expect(result.outcomes == [.renamed(folder, to: rig.at(rig.desk, "Folder 2"), op: .move)])
        #expect(rig.names(rig.at(rig.desk, "Folder 2")) == ["inside.txt"])
    }

    // MARK: Race

    @Test("A destination planted between the check and the move is never overwritten", arguments: [ImportOp.move, .copy])
    func plantedDestination(op: ImportOp) async throws {
        let rig = try FileRig()
        let source = try rig.file(rig.elsewhere, "a.txt", "original")
        let planted = rig.at(rig.desk, "a.txt")
        let once = Once()
        await rig.op.setHooks(.init(beforeRename: { destination in
            once { try? Data("planted".utf8).write(to: destination) }
        }))
        let result = await rig.op.importItems([source], op: op, rig.intent(.drop))
        let second = rig.at(rig.desk, "a 2.txt")
        #expect(result.outcomes == [.renamed(source, to: second, op: op)])
        #expect(rig.text(planted) == "planted")
        #expect(rig.text(second) == "original")
        #expect(rig.exists(source) == (op == .copy))
        #expect(rig.names(rig.desk) == ["a 2.txt", "a.txt"])
    }

    @Test("When every free name is taken at the last moment the drop is refused and nothing is replaced",
          arguments: [ImportOp.move, .copy])
    func plantedEverywhere(op: ImportOp) async throws {
        let rig = try FileRig()
        let source = try rig.file(rig.elsewhere, "a.txt", "original")
        await rig.op.setHooks(.init(beforeRename: { destination in
            try? Data("planted".utf8).write(to: destination)
        }))
        let result = await rig.op.importItems([source], op: op, rig.intent(.drop))
        #expect(result.outcomes == [.refused(source, .noFreeName)])
        #expect(result.undo == nil)
        #expect(rig.text(source) == "original")
        let names = rig.names(rig.desk)
        #expect(names.count == 100)
        #expect(names.allSatisfy { rig.text(rig.desk.appendingPathComponent($0)) == "planted" })
        #expect(!names.contains { $0.hasPrefix(".deskterior-partial-") })
    }

    @Test("Put Back onto a name planted just before the rename lands as \"name 2\"")
    func plantedPutBack() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt", "mine")
        let trashed = await rig.op.trash([a], expecting: [rig.key(a)], rig.intent())
        let once = Once()
        await rig.op.setHooks(.init(beforeRename: { destination in
            once { try? Data("planted".utf8).write(to: destination) }
        }))
        let undo = try #require(trashed.undo)
        let result = await rig.op.undo(undo, rig.intent(.undo))
        #expect(result.outcomes.count == 1)
        #expect(result.outcomes.first?.destination?.lastPathComponent == "a 2.txt")
        #expect(rig.text(a) == "planted")
        #expect(rig.text(rig.at(rig.desk, "a 2.txt")) == "mine")
        #expect(rig.trashNames.isEmpty)
    }

    // MARK: Time of check

    @Test("Trash aborts when the item's inode or volume is not the one expected")
    func timeOfCheck() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt", "old")
        let oldKey = rig.key(a)
        // Replace a.txt with a different file (a new inode) after the token was made.
        let b = try rig.file(rig.desk, ".swap", "new")
        #expect(rename(b.path, a.path) == 0)
        #expect(rig.key(a) != oldKey)

        var result = await rig.op.trash([a], expecting: [oldKey], rig.intent())
        #expect(result.outcomes == [.refused(a, .identityChanged)])
        #expect(result.undo == nil)
        #expect(rig.text(a) == "new")
        #expect(rig.trashNames.isEmpty)

        var wrongVolume = rig.key(a)
        wrongVolume.volume = "SOME-OTHER-VOLUME"
        result = await rig.op.trash([a], expecting: [wrongVolume], rig.intent())
        #expect(result.outcomes == [.refused(a, .identityChanged)])

        let gone = rig.at(rig.desk, "gone.txt")
        result = await rig.op.trash([gone], expecting: [oldKey], rig.intent())
        #expect(result.outcomes == [.refused(gone, .missing)])
        #expect(rig.exists(a))
    }

    @Test("A swap right before the re-stat is caught at the time of check")
    func swapAtCheck() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt", "old")
        let key = rig.key(a)
        let desk = rig.desk
        await rig.op.setHooks(.init(beforeCheck: { url in
            guard url.lastPathComponent == "a.txt" else { return }
            let swap = desk.appendingPathComponent(".swap")
            try? Data("new".utf8).write(to: swap)
            _ = rename(swap.path, url.path)
        }))
        let result = await rig.op.trash([a], expecting: [key], rig.intent())
        #expect(result.outcomes == [.refused(a, .identityChanged)])
        #expect(rig.text(a) == "new")
        #expect(rig.trashNames.isEmpty)
    }

    @Test("Undo aborts when the trashed item was replaced")
    func undoTimeOfCheck() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt")
        let result = await rig.op.trash([a], expecting: [rig.key(a)], rig.intent())
        let record = try #require(result.undo)
        guard case let .putBack(trashed?, _, _) = record.steps.first else { Issue.record("no trash URL"); return }
        let swap = try rig.file(rig.trasher.folder, ".swap", "impostor")
        #expect(rename(swap.path, trashed.path) == 0)
        let undone = await rig.op.undo(record, rig.intent(.undo))
        #expect(undone.outcomes == [.refused(trashed, .identityChanged)])
        #expect(!rig.exists(a))
        #expect(rig.text(trashed) == "impostor")
    }

    // MARK: Confinement

    @Test("Targets must be direct children of the desktop folder: outside paths, nesting, .. and symlinked folders are refused")
    func rootConfinement() async throws {
        let rig = try FileRig()
        let outside = try rig.file(rig.elsewhere, "outside.txt")
        let sub = try rig.temp.mkdir("Desk/sub")
        let nested = try rig.file(sub, "nested.txt")
        let dotdot = rig.at(rig.desk, "../Elsewhere/outside.txt")
        let link = rig.at(rig.desk, "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: rig.elsewhere)
        let throughLink = link.appendingPathComponent("outside.txt")
        let urls = [outside, nested, dotdot, throughLink, rig.desk, rig.at(rig.desk, ".."),
                    rig.at(rig.desk, ".")]
        let keys = urls.map { rig.key($0) }
        let result = await rig.op.trash(urls, expecting: keys, rig.intent())
        #expect(result.outcomes == urls.map { .refused($0, .outsideRoot) })
        #expect(rig.exists(outside) && rig.exists(nested) && rig.exists(link))
        #expect(rig.trashNames.isEmpty)
    }

    @Test("A symlink on the desk is trashed as the link; its target is never touched")
    func symlinkItem() async throws {
        let rig = try FileRig()
        let target = try rig.file(rig.elsewhere, "target.txt", "keep me")
        let link = rig.at(rig.desk, "shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = await rig.op.trash([link], expecting: [rig.key(link)], rig.intent())
        #expect(result.refusals.isEmpty)
        #expect(!rig.exists(link))
        #expect(rig.text(target) == "keep me")
        #expect(rig.trashNames == ["shortcut"])
        // The expected identity is the link's own, not its target's.
        let again = try rig.file(rig.desk, "again.txt")
        try FileManager.default.createSymbolicLink(at: rig.at(rig.desk, "l2"), withDestinationURL: again)
        let viaTarget = await rig.op.trash([rig.at(rig.desk, "l2")], expecting: [rig.key(again)], rig.intent())
        #expect(viaTarget.refusals == [.identityChanged])
    }

    @Test("Demo and test modes refuse anything outside the sandbox roots")
    func sandbox() async throws {
        let rig = try FileRig()
        let other = try TempDesk()
        let foreign = try rig.file(other.root, "foreign.txt", "keep")

        // A drop source outside the sandbox.
        var result = await rig.op.importItems([foreign], op: .move, rig.intent(.drop))
        #expect(result.outcomes == [.refused(foreign, .outsideSandbox)])
        #expect(rig.text(foreign) == "keep")

        // A desktop folder outside the sandbox.
        let a = try rig.file(rig.desk, "a.txt")
        let narrow = rig.makeOperator(sandboxRoots: [rig.elsewhere])
        result = await narrow.trash([a], expecting: [rig.key(a)], rig.intent())
        #expect(result.outcomes == [.refused(a, .outsideSandbox)])
        result = await narrow.importItems([try rig.file(rig.elsewhere, "b.txt")], op: .move, rig.intent(.drop))
        #expect(result.refusals == [.outsideSandbox])

        // A trash folder outside the sandbox.
        let foreignTrash = try FakeTrasher(folder: other.url("Trash"), desktop: rig.desk)
        let leaky = rig.makeOperator(trasher: foreignTrash)
        result = await leaky.trash([a], expecting: [rig.key(a)], rig.intent())
        #expect(result.outcomes == [.refused(a, .outsideSandbox)])
        #expect(rig.exists(a))
        #expect(rig.names(foreignTrash.folder).isEmpty)
    }

    @Test("Dropping the desktop folder, a folder holding it or an item already on it changes nothing")
    func dropEdgeCases() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt")
        let viaDots = rig.at(rig.elsewhere, "../Desk/a.txt")
        let result = await rig.op.importItems([rig.desk, rig.temp.root, a, viaDots], op: .move, rig.intent(.drop))
        #expect(result.outcomes == [
            .refused(rig.desk, .containsDesktop), .refused(rig.temp.root, .containsDesktop), .unchanged(a), .unchanged(viaDots),
        ])
        #expect(result.undo == nil)
        #expect(rig.names(rig.desk) == ["a.txt"])
    }

    @Test("A trash request whose URLs and identities do not pair up is refused whole")
    func mismatched() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt")
        let b = try rig.file(rig.desk, "b.txt")
        let result = await rig.op.trash([a, b], expecting: [rig.key(a)], rig.intent())
        #expect(result.outcomes == [.refused(a, .mismatchedRequest), .refused(b, .mismatchedRequest)])
        #expect(rig.names(rig.desk) == ["a.txt", "b.txt"])
    }

    // MARK: Undo

    @Test("FakeTrash undo restores names, inodes and contents exactly")
    func fakeTrashUndo() async throws {
        let rig = try FileRig()
        let file = try rig.file(rig.desk, "note.txt", "hello")
        let folder = try rig.temp.mkdir("Desk/Projects")
        try rig.file(folder, "plan.md", "plan")
        let pkg = try rig.package(rig.desk, "Notes.rtfd")
        let urls = [file, folder, pkg]
        let before = urls.map { rig.key($0) }

        let trashed = await rig.op.trash(urls, expecting: before, rig.intent())
        #expect(trashed.refusals.isEmpty)
        #expect(rig.names(rig.desk).isEmpty)
        #expect(rig.trashNames == ["Notes.rtfd", "Projects", "note.txt"])
        let record = try #require(trashed.undo)
        #expect(record.kind == .trash)
        #expect(record.steps.count == 3)

        let undone = await rig.op.undo(record, rig.intent(.undo))
        #expect(undone.refusals.isEmpty)
        #expect(undone.outcomes.map { $0.destination?.lastPathComponent } == ["Notes.rtfd", "Projects", "note.txt"])
        #expect(urls.map { rig.key($0) } == before)
        #expect(rig.text(file) == "hello")
        #expect(rig.text(folder.appendingPathComponent("plan.md")) == "plan")
        #expect(rig.names(pkg) == ["TXT.rtf", "image.png"])
        #expect(rig.trashNames.isEmpty)

        // A record is good for one undo; a replay changes nothing.
        let again = await rig.op.undo(record, rig.intent(.undo))
        #expect(again.refusals == [.unknownRecord, .unknownRecord, .unknownRecord])
        #expect(urls.map { rig.key($0) } == before)
    }

    @Test("Undo only renames out of our own trash and only back onto the desk")
    func undoConfinement() async throws {
        let rig = try FileRig()
        let stray = try rig.file(rig.elsewhere, "stray.txt", "stay")
        let onDesk = try rig.file(rig.desk, "on desk.txt")
        let steps: [FileUndoRecord.Step] = [
            .putBack(trashed: stray, original: rig.at(rig.desk, "stray.txt"), key: rig.key(stray)),
            .putBack(trashed: nil, original: rig.at(rig.desk, "lost.txt"), key: rig.key(stray)),
            .moveBack(current: stray, source: rig.at(rig.elsewhere, "x.txt"), key: rig.key(stray)),
            .trashCopy(stray, key: rig.key(stray)),
            .moveBack(current: onDesk, source: URL(fileURLWithPath: "/private/var/root/x.txt"), key: rig.key(onDesk)),
        ]
        let record = try #require(await rig.op.issue(.trash, steps))
        let result = await rig.op.undo(record, rig.intent(.undo))
        #expect(result.refusals == [.outsideSandbox, .outsideRoot, .outsideRoot, .notInTrash, .notInTrash])
        #expect(rig.text(stray) == "stay")
        #expect(rig.exists(onDesk))

        // A trashed item whose recorded place is no longer on the desk stays in the trash.
        let a = try rig.file(rig.desk, "a.txt")
        let trashed = await rig.op.trash([a], expecting: [rig.key(a)], rig.intent())
        guard case let .putBack(t?, _, key) = trashed.undo?.steps.first else { Issue.record("no step"); return }
        let away = FileUndoRecord.Step.putBack(trashed: t, original: rig.at(rig.elsewhere, "a.txt"), key: key)
        let moved = try #require(await rig.op.issue(.trash, [away]))
        let refused = await rig.op.undo(moved, rig.intent(.undo))
        #expect(refused.refusals == [.outsideRoot])
        #expect(rig.trashNames == ["a.txt"])
    }

    @Test("Undo of a drop: a move goes back where it came from, a copy goes to the trash")
    func importUndo() async throws {
        let rig = try FileRig()
        let moving = try rig.file(rig.elsewhere, "moving.txt", "m")
        let copying = try rig.file(rig.elsewhere, "copying.txt", "c")
        let movingInode = rig.inode(moving)
        let moved = await rig.op.importItems([moving], op: .move, rig.intent(.drop))
        let copied = await rig.op.importItems([copying], op: .copy, rig.intent(.drop))
        #expect(rig.names(rig.desk) == ["copying.txt", "moving.txt"])
        #expect(rig.inode(rig.at(rig.desk, "moving.txt")) == movingInode)
        #expect(!rig.exists(moving))

        let undoMove = await rig.op.undo(try #require(moved.undo), rig.intent(.undo))
        #expect(undoMove.outcomes == [.moved(rig.at(rig.desk, "moving.txt"), to: moving)])
        #expect(rig.inode(moving) == movingInode)
        #expect(rig.text(moving) == "m")

        let undoCopy = await rig.op.undo(try #require(copied.undo), rig.intent(.undo))
        #expect(undoCopy.refusals.isEmpty)
        #expect(rig.names(rig.desk).isEmpty)
        #expect(rig.trashNames == ["copying.txt"])
        #expect(rig.text(copying) == "c")
    }

    // MARK: Copies

    @Test("A failed copy leaves no partial file behind and the source untouched")
    func partialCleanup() async throws {
        let rig = try FileRig()
        let folder = try rig.temp.mkdir("Elsewhere/Album")
        try rig.file(folder, "a.jpg", "a")
        let locked = try rig.file(folder, "b.jpg", "b")
        #expect(chmod(locked.path, 0) == 0)
        defer { chmod(locked.path, 0o644) }
        let result = await rig.op.importItems([folder], op: .copy, rig.intent(.drop))
        #expect(result.outcomes == [.refused(folder, .notPermitted)])
        #expect(result.undo == nil)
        #expect(rig.names(rig.desk).isEmpty)
        #expect(rig.names(folder) == ["a.jpg", "b.jpg"])
        let entry = try #require(rig.log.entries().last)
        #expect(entry.op == .importCopy)
        #expect(entry.outcome == "refused: not-permitted")
    }

    @Test("A cross-volume move is a copy: the source is never deleted", arguments: [ImportOp.move, .copy])
    func crossVolume(op: ImportOp) async throws {
        let other = "VOLUME-B"
        let rig = try FileRig(volumeID: { url in url.path.contains("/Elsewhere") ? other : "VOLUME-A" })
        let source = try rig.file(rig.elsewhere, "photo.png", "pixels")
        let pkg = try rig.package(rig.elsewhere, "Notes.rtfd")
        let inodes = [rig.inode(source), rig.inode(pkg)]
        let result = await rig.op.importItems([source, pkg], op: op, rig.intent(.drop))
        let dest = [rig.at(rig.desk, "photo.png"), rig.at(rig.desk, "Notes.rtfd")]
        #expect(result.outcomes == [.copied(source, to: dest[0]), .copied(pkg, to: dest[1])])
        #expect([rig.inode(source), rig.inode(pkg)] == inodes)
        #expect(rig.text(source) == "pixels")
        #expect(rig.names(pkg) == ["TXT.rtf", "image.png"])
        #expect(rig.text(dest[0]) == "pixels")
        #expect(rig.names(dest[1]) == ["TXT.rtf", "image.png"])
        #expect(rig.inode(dest[0]) != inodes[0])

        // Undo trashes our copies; the sources stay.
        _ = await rig.op.undo(try #require(result.undo), rig.intent(.undo))
        #expect(rig.names(rig.desk).isEmpty)
        #expect(rig.text(source) == "pixels")
        #expect(rig.names(pkg) == ["TXT.rtf", "image.png"])
    }

    @Test("An item whose volume cannot be named is copied, not moved")
    func unknownVolume() async throws {
        let rig = try FileRig(volumeID: { url in url.path.contains("/Elsewhere") ? nil : "VOLUME-A" })
        let source = try rig.file(rig.elsewhere, "a.txt")
        let result = await rig.op.importItems([source], op: .move, rig.intent(.drop))
        #expect(result.outcomes == [.copied(source, to: rig.at(rig.desk, "a.txt"))])
        #expect(rig.exists(source))
    }

    @Test("Packages move as one unit and copy whole")
    func packages() async throws {
        let rig = try FileRig()
        let moving = try rig.package(rig.elsewhere, "Moving.rtfd")
        let copying = try rig.package(rig.elsewhere, "Copying.rtfd")
        let inode = rig.inode(moving)
        let moved = await rig.op.importItems([moving], op: .move, rig.intent(.drop))
        let copied = await rig.op.importItems([copying], op: .copy, rig.intent(.drop))
        let m = rig.at(rig.desk, "Moving.rtfd"), c = rig.at(rig.desk, "Copying.rtfd")
        #expect(moved.outcomes == [.moved(moving, to: m)])
        #expect(copied.outcomes == [.copied(copying, to: c)])
        #expect(rig.inode(m) == inode)
        #expect(!rig.exists(moving))
        #expect(rig.names(m) == ["TXT.rtf", "image.png"])
        #expect(rig.names(c) == ["TXT.rtf", "image.png"])
        #expect(rig.names(copying) == ["TXT.rtf", "image.png"])
        #expect(rig.names(rig.desk) == ["Copying.rtfd", "Moving.rtfd"])

        // A taken package name numbers before the extension.
        let again = try rig.package(rig.elsewhere, "Moving.rtfd")
        let renamed = await rig.op.importItems([again], op: .move, rig.intent(.drop))
        #expect(renamed.outcomes == [.renamed(again, to: rig.at(rig.desk, "Moving 2.rtfd"), op: .move)])
    }

    // MARK: Names

    @Test("NFD and NFC spellings of one name collide; Korean NFD names arrive intact")
    func unicodeNames() async throws {
        let rig = try FileRig()
        let composed = "caf\u{E9}.txt", decomposed = "cafe\u{301}.txt"
        let mine = try rig.file(rig.desk, composed, "mine")
        let dropped = try rig.file(rig.elsewhere, decomposed, "dropped")
        let result = await rig.op.importItems([dropped], op: .move, rig.intent(.drop))
        #expect(result.outcomes.count == 1)
        guard case let .renamed(_, to, .move) = result.outcomes[0] else { Issue.record("\(result.outcomes)"); return }
        #expect(nfc(to.lastPathComponent) == nfc("caf\u{E9} 2.txt"))
        #expect(rig.text(mine) == "mine")
        #expect(rig.names(rig.desk) == [nfc("caf\u{E9} 2.txt"), nfc(composed)])

        let korean = "\u{1107}\u{1169}\u{1100}\u{1169}\u{1109}\u{1165}.txt" // 보고서.txt, decomposed
        let report = try rig.file(rig.elsewhere, korean, "report")
        let imported = await rig.op.importItems([report], op: .copy, rig.intent(.drop))
        #expect(imported.refusals.isEmpty)
        #expect(rig.names(rig.desk).contains(nfc("보고서.txt")))

        // Trashing by the other spelling finds the same item.
        let byNFC = rig.at(rig.desk, nfc("보고서.txt"))
        let trashed = await rig.op.trash([byNFC], expecting: [rig.key(byNFC)], rig.intent())
        #expect(trashed.refusals.isEmpty)
        #expect(rig.trashNames == [nfc("보고서.txt")])
    }

    // MARK: Log

    @Test("Every outcome is logged with its op, origin, names and inodes")
    func logging() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt")
        let key = rig.key(a)
        _ = await rig.op.trash([a], expecting: [key], rig.intent(.sheetConfirm))
        let b = try rig.file(rig.desk, "b.txt")
        _ = await rig.op.trash([b], expecting: [key], rig.intent())
        _ = try rig.file(rig.desk, "c.txt")
        let c = try rig.file(rig.elsewhere, "c.txt")
        _ = await rig.op.importItems([c], op: .move, rig.intent(.drop))
        let entries = rig.log.entries()
        #expect(entries.map(\.op) == [.trash, .trash, .importMove])
        #expect(entries.map(\.origin) == [.sheetConfirm, .menuItem, .drop])
        #expect(entries.map(\.outcome) == ["ok", "refused: identity-changed", "renamed"])
        #expect(entries[0].names == ["a.txt"])
        #expect(entries[0].inodes == [key.inode])
        #expect(entries[2].names == ["c.txt", "c 2.txt"])
        #expect(entries.allSatisfy { $0.time == rig.clock.now })
    }

    // MARK: Eject

    @Test("Eject never runs in demo and test modes, and only ever targets a mount point other than the startup disk")
    func eject() async throws {
        let rig = try FileRig()
        #expect(await rig.op.eject(rig.desk, rig.intent()) == .refused(rig.desk, .outsideSandbox))
        #expect(await rig.op.eject(rig.desk, rig.intent(age: 60)) == .refused(rig.desk, .staleIntent))
        #expect(!FileOperator.isEjectableVolume(URL(fileURLWithPath: "/")))
        #expect(!FileOperator.isEjectableVolume(rig.desk))
        #expect(rig.log.entries().map(\.op) == [.eject, .eject])
    }
}
