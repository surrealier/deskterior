import DeskCore
import Foundation
import Testing
@testable import DeskFiles

@Suite("StateStore and IconCache")
struct StateStoreTests {
    static func state(step: Int) -> DeskState {
        var s = DeskState()
        let snap = DesktopSnapshot(
            rootPath: "/fake/Desktop", rootVolume: "V",
            entries: [DesktopEntry(key: TokenKey(volume: "V", inode: 1), meta: TokenMeta(name: "a.txt", kind: .text))],
            scannedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        _ = reduce(&s, .snapshot(snap, now: snap.scannedAt), ReduceEnv(now: snap.scannedAt))
        s.flags.onboardingStep = step
        return s
    }

    func step(_ url: URL) -> Int? {
        (try? Data(contentsOf: url)).flatMap { try? DeskDocument.decode($0) }?.flags.onboardingStep
    }

    @Test("Save then load round-trips through desk.json")
    func roundTrip() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.url("state", isDirectory: true))
        #expect(store.load().source == .fresh)
        let s = Self.state(step: 3)
        try store.save(s, now: Date(timeIntervalSince1970: 1_800_000_100))
        let loaded = store.load()
        #expect(loaded.source == .primary && loaded.problems.isEmpty && loaded.corruptCopy == nil)
        #expect(loaded.document?.makeState() == s)
        #expect(loaded.document?.savedAt == Date(timeIntervalSince1970: 1_800_000_100))
    }

    @Test("Saves rotate three backups, newest first")
    func rotation() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        for i in 1...5 { try store.save(Self.state(step: i)) }
        #expect(step(store.fileURL) == 5)
        #expect(step(store.backupURL(1)) == 4)
        #expect(step(store.backupURL(2)) == 3)
        #expect(step(store.backupURL(3)) == 2)
        #expect(!FileManager.default.fileExists(atPath: d.url("desk.json.bak4").path))
    }

    @Test("A corrupt desk.json falls back to the newest good backup and is kept aside")
    func corruptFallback() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        for i in 1...3 { try store.save(Self.state(step: i)) }
        let garbage = Data("{\"schema\": 1, \"tokens\": 7".utf8)
        try garbage.write(to: store.fileURL)
        try Data("not json".utf8).write(to: store.backupURL(1))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let loaded = store.load(now: now)
        #expect(loaded.source == .backup(2))
        #expect(loaded.document?.flags.onboardingStep == 1)
        #expect(loaded.problems.count == 2)
        let copy = try #require(loaded.corruptCopy)
        #expect(copy.lastPathComponent == "desk.corrupt-20270115-080000.json")
        #expect(try Data(contentsOf: copy) == garbage)
        // Loading again does not pile up copies of the same bytes.
        #expect(store.load(now: now).corruptCopy == copy)
        // The next save does not rotate the corrupt file into the backups.
        try store.save(Self.state(step: 9))
        #expect(step(store.fileURL) == 9)
        #expect(step(store.backupURL(1)) == nil)
    }

    @Test("All files corrupt: start fresh, keep the bad file")
    func allCorrupt() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        try Data("{oops".utf8).write(to: store.fileURL)
        for n in 1...3 { try Data("[\(n)]".utf8).write(to: store.backupURL(n)) }
        let loaded = store.load()
        #expect(loaded.source == .fresh && loaded.document == nil)
        #expect(loaded.problems.count == 4)
        #expect(loaded.corruptCopy.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test("A newer schema is not loaded and not lost")
    func newerSchema() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        try store.save(Self.state(step: 1))
        try store.save(Self.state(step: 2))
        let future = Data("{\"schema\": 7}".utf8)
        try future.write(to: store.fileURL)
        let loaded = store.load()
        #expect(loaded.source == .backup(1) && loaded.document?.flags.onboardingStep == 1)
        #expect(try loaded.corruptCopy.map { try Data(contentsOf: $0) } == future)
    }

    @Test("A missing desk.json is a fresh desk even when backups exist (a reset)")
    func missingPrimary() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.root)
        try store.save(Self.state(step: 1))
        try store.save(Self.state(step: 2))
        try FileManager.default.removeItem(at: store.fileURL)
        #expect(store.load().source == .fresh)
    }

    @Test("State and cache folders inside the desktop are refused; nothing is created there")
    func refusesDesktop() throws {
        let d = try TempDesk()
        let fakeDesk = try d.mkdir("FakeDesk")
        #expect(throws: SafetyGuard.Refusal.self) { try StateStore(directory: fakeDesk.appendingPathComponent("state"), desktop: fakeDesk) }
        #expect(throws: SafetyGuard.Refusal.self) { try IconCache(directory: fakeDesk.appendingPathComponent("icons"), desktop: fakeDesk) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fakeDesk.path).isEmpty)
    }

    @Test("Default locations follow the bundle id")
    func defaultLocations() {
        #expect(StateStore.defaultDirectory(bundleID: "io.example.desk").path.hasSuffix("Library/Application Support/io.example.desk"))
        #expect(IconCache.defaultDirectory(bundleID: "io.example.desk").path.hasSuffix("Library/Caches/io.example.desk/icons"))
    }

    @Test("Icon cache keys cover inode, mtime, size, kind, pixels and palette version")
    func iconKeys() {
        let t = Date(timeIntervalSince1970: 1_800_000_000.5)
        let base = IconCache.key(inode: 1, modified: t, size: 10, kind: .image, pixels: 16, paletteVersion: 1)
        #expect(IconCache.isValidKey(base))
        #expect(base == IconCache.key(inode: 1, modified: t, size: 10, kind: .image, pixels: 16, paletteVersion: 1))
        let variants = [
            IconCache.key(inode: 2, modified: t, size: 10, kind: .image, pixels: 16, paletteVersion: 1),
            IconCache.key(inode: 1, modified: t + 0.001, size: 10, kind: .image, pixels: 16, paletteVersion: 1),
            IconCache.key(inode: 1, modified: nil, size: 10, kind: .image, pixels: 16, paletteVersion: 1),
            IconCache.key(inode: 1, modified: t, size: 11, kind: .image, pixels: 16, paletteVersion: 1),
            IconCache.key(inode: 1, modified: t, size: 10, kind: .screenshot, pixels: 16, paletteVersion: 1),
            IconCache.key(inode: 1, modified: t, size: 10, kind: .image, pixels: 12, paletteVersion: 1),
            IconCache.key(inode: 1, modified: t, size: 10, kind: .image, pixels: 16, paletteVersion: 2),
        ]
        #expect(Set(variants + [base]).count == variants.count + 1)
    }

    @Test("Icon cache stores and loads PNG bytes under valid keys only")
    func iconCache() throws {
        let d = try TempDesk()
        let cache = try IconCache(directory: d.url("icons", isDirectory: true))
        let key = IconCache.key(inode: 5, modified: nil, size: nil, kind: .app, pixels: 16, paletteVersion: 1)
        #expect(cache.load(key) == nil)
        try cache.store(Data([1, 2, 3]), for: key)
        #expect(cache.load(key) == Data([1, 2, 3]))
        #expect(cache.url(for: "../../escape") == nil)
        #expect(throws: SafetyGuard.Refusal.self) { try cache.store(Data(), for: "../../escape") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path) == ["\(key).png"])
    }
}
