import DeskCore
import Foundation
import Testing
@testable import DeskFiles

/// `memos.json` (Erratum 31): sticky notes, day pages and the D-Day, saved beside `desk.json` in our own state folder
/// with backups by age, a kept copy of a corrupt file, and never written over a newer or unreadable one.
@Suite("StateStore memos")
struct StateStoreMemosTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A book with `n` notes ("note 1"…), a Korean day page and a D-Day.
    static func book(_ n: Int = 2, page: String = "회의 3시\n자료 준비") -> MemoBook {
        var b = MemoBook()
        for i in 1...max(n, 1) {
            let id = NoteID(i)
            b.notes[id] = StickyNote(
                id: id, text: i == 1 ? "우유 사기" : "note \(i)", colour: i == 2 ? .pink : .yellow,
                pos: ArtPoint(371, 67), z: i - 1, day: i == 2 ? DayKey("2026-10-30") : nil,
                created: t0, edited: t0.addingTimeInterval(Double(i))
            )
        }
        b.pages[DayKey("2026-10-18")!] = page
        b.dDay = DDay(day: DayKey("2026-10-30")!, title: "중간고사")
        b.nextNote = max(n, 1) + 1
        return b
    }

    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// The first note's text in the memos file at `url`.
    func firstNote(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { try? MemoDocument.decode($0) }?.makeBook().notes[NoteID(1)]?.text
    }

    @Test("Save then load round-trips the book through memos.json, the only file written, in our own folder")
    func roundTrip() throws {
        let d = try TempDesk()
        let dir = d.url("state", isDirectory: true)
        let store = try StateStore(directory: dir)
        let fresh = store.loadMemos()
        #expect(fresh.book == nil && fresh.writable && fresh.problems.isEmpty && fresh.corruptCopy == nil)
        #expect(names(dir).isEmpty, "loading writes nothing")
        let book = Self.book()
        try store.saveMemos(book, now: Self.t0)
        #expect(names(dir) == ["memos.json"])
        let loaded = store.loadMemos()
        #expect(loaded.book == book && loaded.writable && loaded.problems.isEmpty)
        #expect(store.memosURL == dir.appendingPathComponent("memos.json") && StateStore.memosFileName == "memos.json")
        // The file is the document: schema 1, keys sorted (stable diffs), the text as written.
        let text = try String(contentsOf: store.memosURL, encoding: .utf8)
        #expect(text.contains("\"schema\" : 1") && text.contains("우유 사기") && text.contains("중간고사"))
        #expect(try MemoDocument.decode(Data(contentsOf: store.memosURL)).makeBook() == book)
        // Memos and the layout are separate files: neither save touches the other.
        try store.save(DeskState(), now: Self.t0)
        #expect(names(dir) == ["desk.json", "memos.json"])
        #expect(store.loadMemos().book == book)
        // A state folder inside the desktop or the mirrored folder is refused, as for desk.json.
        let mirrored = try d.mkdir("Mirrored")
        #expect(throws: SafetyGuard.Refusal.self) {
            try StateStore(directory: mirrored.appendingPathComponent("state"), mirrored: mirrored)
        }
    }

    @Test("Backups rotate by age: a burst of saves keeps the older book in every generation")
    func rotation() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        for i in 1...6 {
            var b = Self.book()
            b.notes[NoteID(1)]?.text = "v\(i)"
            try store.saveMemos(b, now: Self.t0.addingTimeInterval(Double(i)))
        }
        #expect(firstNote(store.memosURL) == "v6")
        #expect((1...3).map { firstNote(store.memosBackupURL($0)) } == ["v1", "v1", "v1"])
        #expect(names(d.root) == ["memos.json", "memos.json.bak1", "memos.json.bak2", "memos.json.bak3"])
        var b = Self.book()
        b.notes[NoteID(1)]?.text = "v7"
        try store.saveMemos(b, now: Self.t0 + 2 * 3600)
        #expect((1...3).map { firstNote(store.memosBackupURL($0)) } == ["v6", "v1", "v1"])
        b.notes[NoteID(1)]?.text = "v8"
        try store.saveMemos(b, now: Self.t0 + 2 * 86400)
        #expect((1...3).map { firstNote(store.memosBackupURL($0)) } == ["v7", "v6", "v1"])
        // A wiped book saved over and over still leaves the notes in a backup.
        for i in 0..<12 { try store.saveMemos(MemoBook(), now: Self.t0 + 2 * 86400 + Double(60 + i)) }
        #expect(store.loadMemos().book?.notes.isEmpty == true)
        #expect((1...3).contains { firstNote(store.memosBackupURL($0)) != nil })
    }

    @Test("A corrupt memos.json is kept aside once and the newest good backup loads; the next save replaces it")
    func corrupt() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        try store.saveMemos(Self.book(1), now: Self.t0)
        try store.saveMemos(Self.book(2), now: Self.t0 + 1)
        let garbage = Data("{\"schema\": 1, \"notes\": 7".utf8)
        try garbage.write(to: store.memosURL)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let loaded = store.loadMemos(now: now)
        #expect(loaded.book == Self.book(1) && loaded.writable, "the backup's book, and it may be saved")
        let copy = try #require(loaded.corruptCopy)
        #expect(copy.lastPathComponent == "memos.corrupt-20270115-080000.json")
        #expect(try Data(contentsOf: copy) == garbage && loaded.problems.count == 1)
        #expect(store.loadMemos(now: now).corruptCopy == copy, "loading again does not pile up copies")
        try store.saveMemos(Self.book(3), now: now + 2 * 3600) // .bak1 is due: the corrupt file is not taken
        #expect(store.loadMemos().book == Self.book(3))
        #expect(names(d.root).filter { $0.hasPrefix("memos.corrupt-") } == [copy.lastPathComponent])
        #expect(try Data(contentsOf: copy) == garbage, "the corrupt file is never thrown away")
        #expect(firstNote(store.memosBackupURL(1)) == "우유 사기", "a corrupt file never becomes a backup")
    }

    @Test("Every file corrupt: no book, the bad file kept; a corrupt file found at save time is kept too")
    func allCorrupt() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        try Data("{oops".utf8).write(to: store.memosURL)
        for n in 1...3 { try Data("[\(n)]".utf8).write(to: store.memosBackupURL(n)) }
        let loaded = store.loadMemos()
        #expect(loaded.book == nil && loaded.writable && loaded.problems.count == 4)
        #expect(loaded.corruptCopy.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        // Garbage written after the load (by someone else) is kept aside before the save replaces it.
        let other = try TempDesk()
        let fresh = try StateStore(directory: other.root)
        try fresh.saveMemos(Self.book(), now: Self.t0)
        try Data("not json".utf8).write(to: fresh.memosURL)
        try fresh.saveMemos(Self.book(1), now: Self.t0 + 10)
        let kept = names(other.root).filter { $0.hasPrefix("memos.corrupt-") }
        #expect(kept.count == 1 && (try? Data(contentsOf: other.url(kept[0]))) == Data("not json".utf8))
        #expect(fresh.loadMemos().book == Self.book(1))
    }

    @Test("A memos.json from a newer Deskterior is not loaded, not called corrupt, and never written over")
    func newerSchema() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        try store.saveMemos(Self.book(1), now: Self.t0)
        try store.saveMemos(Self.book(2), now: Self.t0 + 1)
        let future = Data("{\"schema\": 2, \"notes\": [], \"stickers\": {}}".utf8)
        try future.write(to: store.memosURL)
        let before = names(d.root)
        let loaded = store.loadMemos()
        #expect(!loaded.writable && loaded.corruptCopy == nil && loaded.problems.count == 1)
        #expect(loaded.book == Self.book(1), "the backup shows, read-only")
        #expect(names(d.root) == before)
        #expect(throws: StateStore.Failure.newerMemos(2)) { try store.saveMemos(Self.book(3), now: Self.t0 + 3 * 86400) }
        #expect(try Data(contentsOf: store.memosURL) == future)
        #expect(firstNote(store.memosBackupURL(1)) == "우유 사기" && names(d.root) == before, "nothing rotated either")
        // A newer backup is skipped, not taken.
        let other = try TempDesk()
        let s2 = try StateStore(directory: other.root)
        try Data("{oops".utf8).write(to: s2.memosURL)
        try future.write(to: s2.memosBackupURL(1))
        let l2 = s2.loadMemos()
        #expect(l2.book == nil && l2.problems.count == 2)
    }

    @Test("A memos.json that cannot be read is never written over",
          arguments: ["folder", "symlink", "fifo", "unreadable", "huge"])
    func unreadable(kind: String) throws {
        let d = try TempDesk()
        let state = try d.mkdir("state")
        let store = try StateStore(directory: state)
        try store.saveMemos(Self.book(1), now: Self.t0)
        try store.saveMemos(Self.book(2), now: Self.t0 + 1)
        try FileManager.default.removeItem(at: store.memosURL)
        let target = try d.write("elsewhere.json", "{\"schema\": 1}")
        switch kind {
        case "folder":
            try FileManager.default.createDirectory(at: store.memosURL, withIntermediateDirectories: false)
        case "symlink":
            try FileManager.default.createSymbolicLink(at: store.memosURL, withDestinationURL: target)
        case "fifo":
            #expect(mkfifo(store.memosURL.path, 0o600) == 0)
        case "unreadable":
            try Data("{}".utf8).write(to: store.memosURL)
            #expect(chmod(store.memosURL.path, 0) == 0)
        default:
            FileManager.default.createFile(atPath: store.memosURL.path, contents: nil)
            let h = try FileHandle(forWritingTo: store.memosURL)
            try h.truncate(atOffset: UInt64(StateStore.maxMemosBytes + 1)) // sparse: no 32 MB written
            try h.close()
        }
        defer { chmod(store.memosURL.path, 0o644) }
        let loaded = store.loadMemos() // a FIFO does not block it
        #expect(!loaded.writable && loaded.book == Self.book(1) && loaded.problems.count == 1, "\(kind)")
        #expect(throws: StateStore.Failure.self) { try store.saveMemos(Self.book(3), now: Self.t0 + 9) }
        var st = stat()
        #expect(lstat(store.memosURL.path, &st) == 0)
        switch kind {
        case "folder": #expect(st.st_mode & S_IFMT == S_IFDIR)
        case "symlink": #expect(st.st_mode & S_IFMT == S_IFLNK && (try? String(contentsOf: target, encoding: .utf8)) == "{\"schema\": 1}")
        case "fifo": #expect(st.st_mode & S_IFMT == S_IFIFO)
        default: #expect(st.st_mode & S_IFMT == S_IFREG)
        }
        #expect(firstNote(store.memosBackupURL(1)) == "우유 사기")
    }

    @Test("A FIFO, a symlink or a folder among the backups never blocks, redirects or stops a load or a save")
    func plantedBackups() throws {
        let d = try TempDesk()
        let state = try d.mkdir("state")
        let store = try StateStore(directory: state)
        let target = try d.write("elsewhere.json", "keep me")
        #expect(mkfifo(store.memosBackupURL(1).path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(at: store.memosBackupURL(2), withDestinationURL: target)
        try FileManager.default.createDirectory(at: store.memosBackupURL(3), withIntermediateDirectories: false)
        try Data("{oops".utf8).write(to: store.memosURL)
        let loaded = store.loadMemos() // returns: the FIFO is not waited on, the link not followed
        #expect(loaded.book == nil && loaded.writable && loaded.problems.count == 1)
        for (i, days) in [0.0, 2, 4, 6].enumerated() {
            try store.saveMemos(Self.book(i + 1), now: Self.t0 + days * 86400)
        }
        #expect(store.loadMemos().book == Self.book(4))
        #expect((try? String(contentsOf: target, encoding: .utf8)) == "keep me", "nothing written through the link")
        var st = stat()
        for n in 1...2 {
            // Replaced whole (an atomic write replaces a link itself, never what it points to).
            #expect(lstat(store.memosBackupURL(n).path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG, "bak\(n)")
            #expect(firstNote(store.memosBackupURL(n)) == "우유 사기")
        }
        #expect(lstat(store.memosBackupURL(3).path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR, "a folder there stays")
    }

    @Test("Reset Layout leaves memos.json and its backups as they are")
    func resetLeavesMemos() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.url("state", isDirectory: true))
        try store.save(StateStoreTests.state(step: 4), now: Self.t0)
        try store.saveMemos(Self.book(1), now: Self.t0)
        try store.saveMemos(Self.book(), now: Self.t0 + 1)
        let memos = try Data(contentsOf: store.memosURL)
        let backup = try Data(contentsOf: store.memosBackupURL(1))
        _ = try #require(try store.resetLayout(now: Self.t0 + 60))
        #expect(try Data(contentsOf: store.memosURL) == memos && (try Data(contentsOf: store.memosBackupURL(1))) == backup)
        #expect(store.loadMemos().book == Self.book() && store.load().document?.makeState().tokens.isEmpty == true)
    }

    @Test("A missing memos.json is a fresh book (how a first run looks), even with backups beside it")
    func missing() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        try store.saveMemos(Self.book(1), now: Self.t0)
        try store.saveMemos(Self.book(), now: Self.t0 + 1)
        try FileManager.default.removeItem(at: store.memosURL)
        let loaded = store.loadMemos()
        #expect(loaded.book == nil && loaded.writable && loaded.problems.isEmpty)
        #expect(firstNote(store.memosBackupURL(1)) == "우유 사기", "the backups stay")
    }
}
