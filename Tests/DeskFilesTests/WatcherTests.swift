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

    /// Reduces every snapshot the watcher produced, in order, starting from `state`: each at its own scan time, or with
    /// `base`, on a model clock 10 ms a snapshot after it (the reducer's time windows then do not depend on how late a
    /// busy runner delivered the snapshots).
    func replay(_ log: EventLog, from state: DeskState, after: Int, base: Date? = nil) -> DeskState {
        var s = state
        for (i, snap) in log.all.dropFirst(after).enumerated() {
            let now = base?.addingTimeInterval(0.01 * Double(i + 1)) ?? snap.scannedAt
            _ = reduce(&s, .snapshot(snap, now: now), ReduceEnv(now: now))
        }
        return s
    }

    @Test("A new file appears in a snapshot within a second")
    func add() async throws {
        let (d, w, log) = try await started()
        defer { w.stop() }
        #expect(log.latest?.entries.isEmpty == true)
        // Within a second by design: FSEvents' latency, then the debounce, capped at `maxDelay`.
        #expect(w.latency + w.debounce <= 1 && w.maxDelay == 1)
        let t0 = Date()
        try d.write("new.txt")
        #expect(await waitUntil { log.latestNames().contains("new.txt") })
        // As delivered, by the watcher's own scan time (not when this test's polling woke up), with room to spare:
        // fseventsd and the watcher's utility queue run late on a starved runner.
        let delivered = try #require(log.latest).scannedAt.timeIntervalSince(t0)
        #expect(delivered < 10, "the scan came \(delivered) s after the write")
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
        // The watcher delivers the delete and the re-create as snapshots of their own; whether they lie within the
        // 2 s window is the reducer's call, on the model clock (DeskCore's tests cover the window itself).
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var state = DeskState()
        _ = reduce(&state, .snapshot(log.latest!, now: t0), ReduceEnv(now: t0))
        let key = TokenKey(volume: log.latest!.rootVolume, inode: d.inode("draft.txt"))
        _ = reduce(&state, .move([key], to: .container(.phone, order: 0)), ReduceEnv(now: t0))
        let seen = log.count
        try d.delete("draft.txt")
        #expect(await waitUntil { log.latestNames().isEmpty })
        try d.write("draft.txt", "again")
        #expect(await waitUntil { log.latestNames() == ["draft.txt"] })
        let after = replay(log, from: state, after: seen, base: t0)
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
        let writing = try ContinuousClock().measure { for i in 1...200 { try d.write("file \(i).txt", "\(i)") } }
        #expect(await waitUntil { log.latest?.entries.count == 200 })
        let deliveries = log.count - before
        // At most a snapshot per FSEvents batch, and batches come at most once a `latency` while the files are written
        // (a few more after): so the bound stretches with the burst, should a busy runner hold the writing back.
        let most = max(20, Int(TestClock.seconds(writing) / w.latency) + 3)
        #expect(deliveries >= 1 && deliveries <= most, "\(deliveries) snapshots for one burst written in \(writing)")
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
        // Counted before the move back: while the folder is away a scan only fails, and the stream rescans at once
        // once it is back, which could otherwise land before the count.
        let seen = log.count
        try parent.move("Desk moved", "Desk")
        #expect(await waitUntil { log.count > seen && log.latestNames() == ["a.txt"] })
        // The restarted stream still sees changes.
        try parent.write("Desk/b.txt")
        #expect(await waitUntil { log.latestNames() == ["a.txt", "b.txt"] })
    }

    @Test("Snapshots say whether they follow the previous one: the first and requested rescans do not")
    func continuity() async throws {
        let (d, w, log) = try await started()
        defer { w.stop() }
        #expect(log.latest?.continuous == false)
        try d.write("a.txt")
        #expect(await waitUntil { log.latestNames() == ["a.txt"] })
        #expect(log.latest?.continuous == true)
        var seen = log.count
        w.rescanNow()
        // The rescan's own snapshot, wherever it lands among scans of a late batch for a.txt (continuous ones).
        #expect(await waitUntil { log.all.dropFirst(seen).contains { !$0.continuous } })
        seen = log.count
        w.rescanNow(preservingContinuity: true)
        #expect(await waitUntil { log.count > seen })
        #expect(log.latest?.continuous == true)
    }

    @Test("stop() returns at once during a long scan, and nothing is delivered after it")
    func stopDoesNotWaitForAScan() async throws {
        let d = try TempDesk()
        for i in 0..<3000 { try d.write(String(format: "f%05d.txt", i)) }
        // Best of three watchers: a stop() that waited for the scan would be slow every time, while a starved runner
        // that holds the test back between the clock's two reads does so only now and then.
        var watchers: [(DesktopWatcher, EventLog, stopped: Int)] = []
        var stops: [Duration] = []
        for _ in 0..<3 {
            let log = EventLog()
            let w = DesktopWatcher(scanner: DesktopScanner(root: d.root)) { log.record($0) }
            w.start()
            try await Task.sleep(for: .milliseconds(20))
            stops.append(ContinuousClock().measure { w.stop() })
            watchers.append((w, log, log.count))  // kept: a watcher's deinit waits for its queue
        }
        #expect(try #require(stops.min()) < .milliseconds(100), "stop() took \(stops)")
        try await Task.sleep(for: .milliseconds(1200))
        #expect(watchers.allSatisfy { $0.1.count == $0.stopped })
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
