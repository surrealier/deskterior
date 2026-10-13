import CoreServices
import DeskCore
import Foundation
import Testing
@testable import DeskFiles

/// End-to-end FSEvents tests in scratch folders. Each waits for the debounced snapshot with a timeout.
@Suite("DesktopWatcher", .serialized)
struct WatcherTests {
    /// Starts a watcher on a fresh scratch folder (after `setup`) and waits for the initial snapshot.
    func started(_ setup: (TempDesk) throws -> Void = { _ in }) async throws -> (TempDesk, DesktopWatcher, EventLog) {
        let d = try TempDesk()
        try setup(d)
        let log = EventLog()
        let w = DesktopWatcher(scanner: DesktopScanner(root: d.root)) { log.record($0) }
        w.start()
        #expect(await waitUntil { log.count >= 1 })
        return (d, w, log)
    }

    /// Reduces every snapshot the watcher produced, in order, starting from `state`.
    func replay(_ log: EventLog, from state: DeskState, after: Int) -> DeskState {
        var s = state
        for snap in log.all.dropFirst(after) { _ = reduce(&s, .snapshot(snap, now: snap.scannedAt), ReduceEnv(now: snap.scannedAt)) }
        return s
    }

    @Test("A new file appears in a snapshot within a second")
    func add() async throws {
        let (d, w, log) = try await started()
        defer { w.stop() }
        #expect(log.latest?.entries.isEmpty == true)
        let t0 = Date()
        try d.write("new.txt")
        #expect(await waitUntil { log.latestNames().contains("new.txt") })
        #expect(Date().timeIntervalSince(t0) < 2)
        #expect(log.latest?.entries.first?.key.inode == d.inode("new.txt"))
    }

    @Test("A rename keeps the inode, and the token keeps its place")
    func rename() async throws {
        let (d, w, log) = try await started { try $0.write("old name.txt") }
        defer { w.stop() }
        var state = DeskState()
        _ = reduce(&state, .snapshot(log.latest!, now: Date()), ReduceEnv(now: Date()))
        let key = TokenKey(volume: log.latest!.rootVolume, inode: d.inode("old name.txt"))
        _ = reduce(&state, .move([key], to: .container(.cabinetTop, order: 0)), ReduceEnv(now: Date()))
        let seen = log.count
        try d.move("old name.txt", "new name.txt")
        #expect(await waitUntil { log.latestNames() == ["new name.txt"] })
        #expect(log.latest?.entries.first?.key == key)
        let after = replay(log, from: state, after: seen)
        #expect(after.tokens.location(of: key) == .container(.cabinetTop, order: 0))
        #expect(after.tokens.meta(of: key)?.name == "new name.txt")
    }

    @Test("Safe-save swap: an atomic re-save (new inode, same name) keeps the token's place")
    func safeSave() async throws {
        let (d, w, log) = try await started { try $0.write("doc.txt", "v1") }
        defer { w.stop() }
        var state = DeskState()
        _ = reduce(&state, .snapshot(log.latest!, now: Date()), ReduceEnv(now: Date()))
        let oldInode = d.inode("doc.txt")
        let oldKey = TokenKey(volume: log.latest!.rootVolume, inode: oldInode)
        _ = reduce(&state, .move([oldKey], to: .container(.riserLeft, order: 0)), ReduceEnv(now: Date()))
        let seen = log.count
        try Data("v2".utf8).write(to: d.url("doc.txt"), options: .atomic)
        let newInode = d.inode("doc.txt")
        #expect(newInode != oldInode)
        #expect(await waitUntil { log.latest?.entries.contains { $0.key.inode == newInode } == true })
        let after = replay(log, from: state, after: seen)
        let newKey = TokenKey(volume: log.latest!.rootVolume, inode: newInode)
        #expect(after.tokens.location(of: newKey) == .container(.riserLeft, order: 0))
        #expect(after.tokens.count == 1)
        #expect(after.violations().isEmpty)
    }

    @Test("Delete then re-create under the same name within 2 s keeps the place")
    func deleteAndRecreate() async throws {
        let (d, w, log) = try await started { try $0.write("draft.txt") }
        defer { w.stop() }
        var state = DeskState()
        _ = reduce(&state, .snapshot(log.latest!, now: Date()), ReduceEnv(now: Date()))
        let key = TokenKey(volume: log.latest!.rootVolume, inode: d.inode("draft.txt"))
        _ = reduce(&state, .move([key], to: .container(.phone, order: 0)), ReduceEnv(now: Date()))
        let seen = log.count
        try d.delete("draft.txt")
        #expect(await waitUntil { log.latestNames().isEmpty })
        try d.write("draft.txt", "again")
        #expect(await waitUntil { log.latestNames() == ["draft.txt"] })
        let after = replay(log, from: state, after: seen)
        let newKey = TokenKey(volume: log.latest!.rootVolume, inode: d.inode("draft.txt"))
        #expect(after.tokens.location(of: newKey) == .container(.phone, order: 0))
        #expect(after.tombstones.isEmpty)
    }

    @Test("A deleted file disappears and leaves a tombstone")
    func delete() async throws {
        let (d, w, log) = try await started { try $0.write("gone.txt"); try $0.write("stay.txt") }
        defer { w.stop() }
        var state = DeskState()
        _ = reduce(&state, .snapshot(log.latest!, now: Date()), ReduceEnv(now: Date()))
        let seen = log.count
        try d.delete("gone.txt")
        #expect(await waitUntil { log.latestNames() == ["stay.txt"] })
        let after = replay(log, from: state, after: seen)
        #expect(after.tokens.count == 1)
        #expect(after.tombstones.map(\.name) == ["gone.txt"])
    }

    @Test("Screenshot flow: a hidden dot-file renamed into place appears once, never as a dot-file")
    func dotFileThenRename() async throws {
        let (d, w, log) = try await started()
        defer { w.stop() }
        try d.write(".Screenshot 2026-10-12 at 10.15.32.png", "png")
        try await Task.sleep(for: .milliseconds(700))
        try d.move(".Screenshot 2026-10-12 at 10.15.32.png", "Screenshot 2026-10-12 at 10.15.32.png")
        #expect(await waitUntil { log.latestNames() == ["Screenshot 2026-10-12 at 10.15.32.png"] })
        #expect(log.all.allSatisfy { snap in snap.entries.allSatisfy { !$0.meta.name.hasPrefix(".") } })
        var state = DeskState()
        for snap in log.all { _ = reduce(&state, .snapshot(snap, now: snap.scannedAt), ReduceEnv(now: snap.scannedAt)) }
        #expect(state.tokens.count == 1)
        #expect(state.tokens.records.values.first?.meta.kind == .screenshot)
        #expect(state.tokens.records.values.first?.location == .screen(page: 0, col: 0, row: 0))
    }

    @Test("A burst of 200 files arrives in a few debounced snapshots and lays out in order")
    func burst() async throws {
        let (d, w, log) = try await started()
        defer { w.stop() }
        let before = log.count
        for i in 1...200 { try d.write("file \(i).txt", "\(i)") }
        #expect(await waitUntil(timeout: 10) { log.latest?.entries.count == 200 })
        let deliveries = log.count - before
        #expect(deliveries >= 1 && deliveries <= 20, "\(deliveries) snapshots for one burst")
        var state = DeskState()
        for snap in log.all { _ = reduce(&state, .snapshot(snap, now: snap.scannedAt), ReduceEnv(now: snap.scannedAt)) }
        #expect(state.tokens.count == 200 && state.pageCount() == 5)
        #expect(state.violations().isEmpty)
    }

    @Test("Changes inside subfolders are not top-level changes")
    func relevance() {
        let root = "/private/var/folders/x/desk"
        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        func relevant(_ path: String, _ f: FSEventStreamEventFlags = flags) -> Bool {
            DesktopWatcher.isRelevant(path: path, flags: f, root: root.lowercased())
        }
        #expect(relevant("/private/var/folders/x/desk/a.txt"))
        #expect(relevant("/private/var/folders/x/desk"))
        #expect(relevant("/private/var/folders/x/DESK/B.txt"))
        #expect(!relevant("/private/var/folders/x/desk/sub/inner.txt"))
        #expect(relevant("/private/var/folders/x/desk/sub/inner.txt", FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)))
        #expect(relevant("/somewhere/else"))
        #expect(relevant(""))
    }

    @Test("Moving the folder away and back restarts the stream (RootChanged)")
    func rootChanged() async throws {
        let parent = try TempDesk()
        let folder = try parent.mkdir("Desk")
        try parent.write("Desk/a.txt")
        let log = EventLog()
        let w = DesktopWatcher(scanner: DesktopScanner(root: folder)) { log.record($0) }
        defer { w.stop() }
        w.start()
        #expect(await waitUntil { log.count >= 1 })
        try parent.move("Desk", "Desk moved")
        #expect(await waitUntil { !log.failureList.isEmpty })
        try parent.move("Desk moved", "Desk")
        let seen = log.count
        #expect(await waitUntil { log.count > seen && log.latestNames() == ["a.txt"] })
        // The restarted stream still sees changes.
        try parent.write("Desk/b.txt")
        #expect(await waitUntil { log.latestNames() == ["a.txt", "b.txt"] })
    }

    @Test("rescanNow delivers a snapshot immediately; stop ends delivery")
    func rescanAndStop() async throws {
        let (d, w, log) = try await started()
        let seen = log.count
        w.rescanNow()
        #expect(await waitUntil { log.count > seen })
        w.stop()
        let stopped = log.count
        try d.write("after-stop.txt")
        try await Task.sleep(for: .milliseconds(900))
        #expect(log.count == stopped)
    }
}
