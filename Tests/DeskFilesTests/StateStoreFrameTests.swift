import DeskCore
import Foundation
import Testing
@testable import DeskFiles

/// `frame.json` (Erratum 33): the picture frame's photo, saved beside `memos.json` in our own state folder with backups
/// by age, a kept copy of a corrupt file, and never written over a newer or unreadable one.
@Suite("StateStore frame")
struct StateStoreFrameTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A photo of one colour.
    static func photo(_ ink: Ink) -> FramePhoto {
        FramePhoto(PixelBuffer(width: FramePhoto.size.w, height: FramePhoto.size.h, fill: ink.color))!
    }

    static let blue = photo(.blue3), red = photo(.red3), oak = photo(.oak4), plum = photo(.purple2)

    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// The photo in the frame file at `url` (nil: none, or no frame document).
    func photo(in url: URL) -> FramePhoto? {
        (try? Data(contentsOf: url)).flatMap { try? FrameDocument.decode($0) }?.photo
    }

    /// Whether `error` is `StateStore.Failure.frameUnreadable`.
    func isFrameUnreadable(_ error: StateStore.Failure?) -> Bool {
        if case .frameUnreadable? = error { true } else { false }
    }

    @Test("Save then load round-trips the photo through frame.json, the only file written, in our own folder")
    func roundTrip() throws {
        let d = try TempDesk()
        let dir = d.url("state", isDirectory: true)
        let store = try StateStore(directory: dir)
        let fresh = store.loadFrame()
        #expect(fresh.photo == nil && fresh.writable && fresh.problems.isEmpty && fresh.corruptCopy == nil)
        #expect(names(dir).isEmpty, "loading writes nothing")
        try store.saveFrame(FramePhoto.sample, now: Self.t0)
        #expect(names(dir) == ["frame.json"])
        #expect(names(d.root) == ["state"], "nothing outside the state folder")
        let loaded = store.loadFrame()
        #expect(loaded.photo == FramePhoto.sample && loaded.writable && loaded.problems.isEmpty)
        #expect(store.frameURL == dir.appendingPathComponent("frame.json") && StateStore.frameFileName == "frame.json")
        #expect(store.frameBackupURL(2) == dir.appendingPathComponent("frame.json.bak2"))
        // The file is the document: schema 1, keys sorted, the pixels as 34 rows of 26 characters.
        let text = try String(contentsOf: store.frameURL, encoding: .utf8)
        #expect(text.contains("\"schema\" : 1") && text.contains("\"rows\"") && text.contains(FramePhoto.sample.rows[0]))
        #expect(try FrameDocument.decode(Data(contentsOf: store.frameURL)).photo == FramePhoto.sample)
        // No photo: the file says so, and loads as none, writable.
        try store.saveFrame(nil, now: Self.t0 + 1)
        let none = store.loadFrame()
        #expect(none.photo == nil && none.writable && none.problems.isEmpty)
        #expect(try !String(contentsOf: store.frameURL, encoding: .utf8).contains("\"photo\""))
        #expect(names(dir) == ["frame.json", "frame.json.bak1"])
        #expect(photo(in: store.frameBackupURL(1)) == FramePhoto.sample)
        // A state folder inside the desktop or the mirrored folder is refused, as for desk.json.
        let mirrored = try d.mkdir("Mirrored")
        #expect(throws: SafetyGuard.Refusal.self) {
            try StateStore(directory: mirrored.appendingPathComponent("state"), mirrored: mirrored)
        }
    }

    @Test("Backups rotate by age, not by save: .bak1 keeps an older photo")
    func backups() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        try store.saveFrame(Self.blue, now: Self.t0)
        try store.saveFrame(Self.red, now: Self.t0 + 2 * 3600)
        try store.saveFrame(Self.oak, now: Self.t0 + 3 * 3600)
        #expect(photo(in: store.frameURL) == Self.oak)
        #expect(photo(in: store.frameBackupURL(1)) == Self.red && photo(in: store.frameBackupURL(2)) == Self.blue)
        // A minute later .bak1 is not due: it keeps b, not c (a burst of saves cannot push a photo out of every backup).
        try store.saveFrame(Self.plum, now: Self.t0 + 3 * 3600 + 60)
        try store.saveFrame(nil, now: Self.t0 + 3 * 3600 + 120)
        #expect(store.loadFrame().photo == nil)
        #expect((1...3).map { photo(in: store.frameBackupURL($0)) } == [Self.red, Self.blue, Self.blue])
        #expect(names(d.root) == ["frame.json", "frame.json.bak1", "frame.json.bak2", "frame.json.bak3"])
    }

    @Test("A corrupt frame.json is kept aside and the good backup loads; the next save replaces it")
    func corrupt() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        try store.saveFrame(Self.blue, now: Self.t0)
        try store.saveFrame(Self.red, now: Self.t0 + 1)
        #expect(photo(in: store.frameBackupURL(1)) == Self.blue)
        let garbage = Data("{\"schema\": 1, \"photo\": {\"rows\": 7".utf8)
        try garbage.write(to: store.frameURL)
        let loaded = store.loadFrame(now: Self.t0)
        #expect(loaded.photo == Self.blue && loaded.writable, "the backup's photo, and it may be saved")
        let copy = try #require(loaded.corruptCopy)
        #expect(copy.lastPathComponent == "frame.corrupt-20270115-080000.json")
        #expect(try Data(contentsOf: copy) == garbage && loaded.problems.count == 1)
        #expect(store.loadFrame(now: Self.t0).corruptCopy == copy, "loading again does not pile up copies")
        try store.saveFrame(Self.oak, now: Self.t0 + 2 * 3600) // .bak1 is due: the corrupt file is not taken
        #expect(store.loadFrame().photo == Self.oak)
        #expect(names(d.root).filter { $0.hasPrefix("frame.corrupt-") } == [copy.lastPathComponent])
        #expect(try Data(contentsOf: copy) == garbage, "the corrupt file is never thrown away")
        #expect(photo(in: store.frameBackupURL(1)) == Self.blue, "a corrupt file never becomes a backup")
        // Garbage written after a load (by someone else) is kept aside before a save replaces it.
        try Data("not json".utf8).write(to: store.frameURL)
        try store.saveFrame(Self.plum, now: Self.t0 + 3 * 3600)
        #expect(names(d.root).filter { $0.hasPrefix("frame.corrupt-") }.count == 2)
        #expect(store.loadFrame().photo == Self.plum)
    }

    @Test("A frame.json from a newer Deskterior is not loaded, not called corrupt, and never written over")
    func newer() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        let future = Data("{\"schema\": 2}".utf8)
        try future.write(to: store.frameURL)
        let before = names(d.root)
        let loaded = store.loadFrame()
        #expect(loaded.photo == nil && !loaded.writable && loaded.corruptCopy == nil && loaded.problems.count == 1)
        #expect(names(d.root) == before)
        #expect(throws: StateStore.Failure.newerFrame(2)) { try store.saveFrame(Self.blue, now: Self.t0) }
        #expect(try Data(contentsOf: store.frameURL) == future && names(d.root) == before, "nothing rotated either")
        #expect(StateStore.Failure.newerFrame(2).description
            == "frame.json uses schema 2, newer than \(FrameDocument.currentSchema); not overwriting it")
        // With a backup beside it, the backup shows, read-only; a newer backup is skipped, not taken.
        let other = try TempDesk()
        let s2 = try StateStore(directory: other.root)
        try s2.saveFrame(Self.blue, now: Self.t0)
        try s2.saveFrame(Self.red, now: Self.t0 + 1)
        try future.write(to: s2.frameURL)
        let l2 = s2.loadFrame()
        #expect(l2.photo == Self.blue && !l2.writable)
        try future.write(to: s2.frameBackupURL(1))
        #expect(s2.loadFrame().photo == nil && s2.loadFrame().problems.count == 2)
    }

    @Test("A frame.json that cannot be read is never written over, and never blocks a load",
          arguments: ["fifo", "folder", "symlink", "unreadable", "huge"])
    func unreadable(kind: String) throws {
        let d = try TempDesk()
        let state = try d.mkdir("state")
        let store = try StateStore(directory: state)
        let target = try d.write("elsewhere.json", "{\"schema\": 1}")
        switch kind {
        case "fifo":
            #expect(mkfifo(store.frameURL.path, 0o600) == 0)
        case "folder":
            try FileManager.default.createDirectory(at: store.frameURL, withIntermediateDirectories: false)
        case "symlink":
            try FileManager.default.createSymbolicLink(at: store.frameURL, withDestinationURL: target)
        case "unreadable":
            try Data("{\"schema\": 1}".utf8).write(to: store.frameURL)
            #expect(chmod(store.frameURL.path, 0) == 0)
        default:
            FileManager.default.createFile(atPath: store.frameURL.path, contents: nil)
            let h = try FileHandle(forWritingTo: store.frameURL)
            try h.truncate(atOffset: UInt64(StateStore.maxFrameBytes + 1)) // sparse
            try h.close()
        }
        defer { chmod(store.frameURL.path, 0o644) }
        let before = names(state)
        let loaded = store.loadFrame() // a FIFO does not block it
        #expect(!loaded.writable && loaded.photo == nil && loaded.problems.count == 1, "\(kind)")
        let error = #expect(throws: StateStore.Failure.self) { try store.saveFrame(Self.blue, now: Self.t0) }
        #expect(isFrameUnreadable(error), "\(kind): \(String(describing: error))")
        #expect(names(state) == before, "\(kind): nothing written beside it either")
        var st = stat()
        #expect(lstat(store.frameURL.path, &st) == 0)
        switch kind {
        case "fifo": #expect(st.st_mode & S_IFMT == S_IFIFO)
        case "folder": #expect(st.st_mode & S_IFMT == S_IFDIR)
        case "symlink":
            #expect(st.st_mode & S_IFMT == S_IFLNK)
            #expect((try? String(contentsOf: target, encoding: .utf8)) == "{\"schema\": 1}", "nothing written through the link")
        case "huge": #expect(st.st_mode & S_IFMT == S_IFREG && Int(st.st_size) == StateStore.maxFrameBytes + 1)
        default: #expect(st.st_mode & S_IFMT == S_IFREG)
        }
        #expect(StateStore.Failure.frameUnreadable("is not a regular file").description
            == "frame.json is not a regular file; not overwriting it")
    }

    @Test("Reset Layout leaves frame.json and its backups byte for byte")
    func reset() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.url("state", isDirectory: true))
        try store.save(StateStoreTests.state(step: 4), now: Self.t0)
        try store.saveFrame(Self.blue, now: Self.t0)
        try store.saveFrame(Self.red, now: Self.t0 + 1)
        let frame = try Data(contentsOf: store.frameURL)
        let backup = try Data(contentsOf: store.frameBackupURL(1))
        _ = try #require(try store.resetLayout(now: Self.t0 + 60))
        #expect(try Data(contentsOf: store.frameURL) == frame && (try Data(contentsOf: store.frameBackupURL(1))) == backup)
        #expect(store.loadFrame().photo == Self.red && store.load().document?.makeState().tokens.isEmpty == true)
    }

    @Test("A missing frame.json is no photo, writable (how a first run looks), even with backups beside it")
    func missing() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        try store.saveFrame(Self.blue, now: Self.t0)
        try store.saveFrame(Self.red, now: Self.t0 + 1)
        try FileManager.default.removeItem(at: store.frameURL)
        let loaded = store.loadFrame()
        #expect(loaded.photo == nil && loaded.writable && loaded.problems.isEmpty && loaded.corruptCopy == nil)
        #expect(photo(in: store.frameBackupURL(1)) == Self.blue, "the backups stay")
    }

    @Test("Memos and the frame are separate files: saving one leaves the other byte for byte")
    func independence() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        try store.saveFrame(Self.blue, now: Self.t0)
        let frame = try Data(contentsOf: store.frameURL)
        var book = MemoBook()
        book.pages[DayKey("2026-10-18")!] = "액자에 사진 걸기"
        try store.saveMemos(book, now: Self.t0 + 1)
        try store.save(DeskState(), now: Self.t0 + 2)
        #expect(try Data(contentsOf: store.frameURL) == frame)
        let memos = try Data(contentsOf: store.memosURL)
        try store.saveFrame(Self.red, now: Self.t0 + 3)
        try store.saveFrame(nil, now: Self.t0 + 4)
        #expect(try Data(contentsOf: store.memosURL) == memos)
        #expect(store.loadMemos().book == book && store.loadFrame().photo == nil)
        #expect(names(d.root) == ["desk.json", "frame.json", "frame.json.bak1", "frame.json.bak2", "memos.json"])
    }

    @Test("A regular file is not a file-provider placeholder")
    func dataless() throws {
        let d = try TempDesk()
        let file = try d.write("photo.png", "not really a photo")
        #expect(!DesktopScanner.isDataless(file))
        #expect(!DesktopScanner.isDataless(try d.mkdir("folder")))
        #expect(!DesktopScanner.isDataless(d.url("gone.png")))
    }
}
