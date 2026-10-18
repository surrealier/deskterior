import DeskCore
import DeskFiles
import DeskScene
import Foundation
import Metal
import Testing
@testable import DeskteriorApp

/// A small book: one note and today's page (whole seconds, so it survives the file's millisecond dates).
func memoBook(_ text: String = "우유 사기", page: String = "회의 3시") -> MemoBook {
    var book = MemoBook()
    let t = Date(timeIntervalSince1970: 1_792_300_000)
    book.notes[NoteID(1)] = StickyNote(id: NoteID(1), text: text, colour: .yellow, pos: ArtPoint(371, 67), z: 0,
                                       created: t, edited: t)
    book.pages[DayKey("2026-10-18")!] = page
    book.nextNote = 2
    return book
}

/// Counts calls made on any queue.
nonisolated final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// `memos.json`'s saver (Erratum 31): nothing before `arm()`, debounced, written with no folder connected, flushed
/// when a session stops. Scratch state folders only.
@Suite("Memo saver")
struct MemoSaverTests {
    func memosFile(_ dir: URL) -> URL { dir.appendingPathComponent(StateStore.memosFileName) }

    @Test("Nothing is written before arm(): not a scheduled book, not a flushed one")
    func notBeforeArm() throws {
        let temp = try AppTemp()
        let dir = try temp.dir("State")
        let saver = MemoSaver(store: try StateStore(directory: dir, mirrored: try temp.dir("Desk")), delay: 0.01, maxWait: 0.05)
        saver.schedule(memoBook())
        saver.flush(memoBook())
        Thread.sleep(forTimeInterval: 0.1)
        saver.flush()
        #expect(!saver.isArmed && saver.saveCount == 0)
        #expect(!FileManager.default.fileExists(atPath: memosFile(dir).path))
    }

    @Test("Once armed, a stream of changes is one debounced write, and a flush writes what is pending at once")
    func debounced() async throws {
        let temp = try AppTemp()
        let saver = MemoSaver(store: try StateStore(directory: try temp.dir("State"), mirrored: try temp.dir("Desk")),
                              delay: 0.05, maxWait: 1)
        saver.arm()
        for i in 0..<5 { saver.schedule(memoBook("note \(i)")) }
        #expect(await eventually { saver.saveCount == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(saver.saveCount == 1, "five changes in a row, one write")
        saver.flush()
        #expect(saver.saveCount == 1, "nothing pending: nothing to write")
        saver.schedule(memoBook("later"))
        saver.flush()
        #expect(saver.saveCount == 2, "flush writes the pending book without waiting")
    }

    // Reads back through `StateStore.loadMemos`, the memos.json I/O the app uses.
    @Test("Written with no folder connected (root nil), and read back as it was")
    func noRoot() throws {
        let temp = try AppTemp()
        let dir = try temp.dir("State")
        let store = try StateStore(directory: dir, mirrored: try temp.dir("Desk"))
        let saver = MemoSaver(store: store)
        let model = Store(memoSaver: saver)
        #expect(model.state.root == nil)
        saver.arm()
        saver.flush(memoBook())
        #expect(saver.saveCount == 1)
        #expect(FileManager.default.fileExists(atPath: memosFile(dir).path))
        #expect(store.loadMemos().book == memoBook())
    }

    @Test("A failed write (an unwritable state folder) is kept: the next flush writes it, as quitting or a stop does")
    func failedWriteFlushed() async throws {
        let temp = try AppTemp()
        let dir = try temp.dir("State")
        let store = try StateStore(directory: dir, mirrored: try temp.dir("Desk"))
        let saver = MemoSaver(store: store, delay: 0.01, maxWait: 60)
        saver.arm()
        saver.flush(memoBook("first"))
        chmod(dir.path, 0o500)
        defer { chmod(dir.path, 0o700) }
        saver.schedule(memoBook("typed while the disk was full"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(saver.isArmed && saver.saveCount == 1, "the write failed, and a failed write does not disarm")
        chmod(dir.path, 0o700)
        Store(memoSaver: saver).flush()
        #expect(saver.saveCount == 2)
        #expect(store.loadMemos().book == memoBook("typed while the disk was full"))
    }

    @Test("A failed write is tried again by itself, maxWait later")
    func failedWriteRetried() async throws {
        let temp = try AppTemp()
        let dir = try temp.dir("State")
        let store = try StateStore(directory: dir, mirrored: try temp.dir("Desk"))
        let saver = MemoSaver(store: store, delay: 0.01, maxWait: 0.3)
        saver.arm()
        saver.flush(memoBook("first"))
        chmod(dir.path, 0o500)
        defer { chmod(dir.path, 0o700) }
        saver.schedule(memoBook("typed while the disk was full"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(saver.saveCount == 1)
        chmod(dir.path, 0o700)
        #expect(await eventually { saver.saveCount == 2 })
        #expect(store.loadMemos().book == memoBook("typed while the disk was full"))
    }

    @Test("A book too large to read back is not written and not retried, the user is told once; a smaller one saves")
    func tooLarge() throws {
        let temp = try AppTemp()
        let dir = try temp.dir("State")
        let store = try StateStore(directory: dir, mirrored: try temp.dir("Desk"))
        let refusals = CallCount()
        let saver = MemoSaver(store: store, delay: 0.01, maxWait: 0.05, onRefusal: { refusals.bump() })
        saver.arm()
        saver.flush(memoBook("first"))
        var huge = memoBook("first")
        huge.pages[DayKey("2026-10-19")!] = String(repeating: "x", count: StateStore.maxMemosBytes)
        saver.flush(huge)
        saver.flush(huge)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(saver.isArmed && saver.saveCount == 1 && refusals.value == 1)
        #expect(store.loadMemos().book == memoBook("first"))
        saver.flush(memoBook("smaller"))
        #expect(saver.saveCount == 2 && store.loadMemos().book == memoBook("smaller"))
    }

    @Test("A memos.json that a newer Deskterior wrote mid-session stops the saves: it is never written over")
    func newerFileDisarms() throws {
        let temp = try AppTemp()
        let dir = try temp.dir("State")
        let store = try StateStore(directory: dir, mirrored: try temp.dir("Desk"))
        let refusals = CallCount()
        let saver = MemoSaver(store: store, onRefusal: { refusals.bump() })
        saver.arm()
        saver.flush(memoBook())
        let future = Data("{\"schema\": 2, \"notes\": []}".utf8)
        try future.write(to: memosFile(dir))
        saver.flush(memoBook("later"))
        #expect(!saver.isArmed && saver.saveCount == 1)
        saver.flush(memoBook("later still"))
        #expect(try Data(contentsOf: memosFile(dir)) == future)
        #expect(refusals.value == 1, "the user is told once (the session shows a toast)")
    }
}

/// Sessions as the app starts them, over scratch folders that may share one state folder (a folder switch keeps the
/// app's state folder, so memos.json is the same file).
@MainActor
final class MemoRig {
    let temp: AppTemp
    let state: URL

    init() throws {
        temp = try AppTemp()
        state = try temp.dir("State")
    }

    /// A dry-run session on the scratch folder `desk`, not connected (nothing reads the folder before ⏻).
    func session(_ desk: String = "Desk") throws -> DeskSession {
        let folder = try temp.dir(desk)
        let home = try temp.dir("home"), desktop = try temp.dir("home/Desk")
        let options = try LaunchOptions.parse(["--windowed", "--desktop-folder", folder.path, "--state-dir", state.path,
                                               "--icons", "kind"])
        var configuration = try MirrorController.launch(options: options, environment: [:],
                                                        bundleID: AppIdentity.fallbackBundleID, realDesktop: desktop,
                                                        home: home).get()
        configuration.connectImmediately = false
        configuration.finderHidesItems = false
        configuration.watchesVolumes = false
        let device = try #require(MTLCreateSystemDefaultDevice())
        let host = try SceneHost(grid: PixelGrid(display: DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2,
                                                                          topInsetPt: 33)), device: device)
        AppDelegate.configure(host, options)
        return DeskSession(host: host, options: options, configuration: configuration, dryRun: true)
    }

    var stateStore: StateStore {
        get throws { try StateStore(directory: state, mirrored: temp.root.appendingPathComponent("Desk")) }
    }
}

/// The load and save order of §4.6: memos load after every desk load, the saver arms only after it, and a stop
/// flushes, all through `StateStore.loadMemos` / `saveMemos` in a temporary state folder.
@Suite("Memos across sessions", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct MemoSessionTests {
    @Test("A session loads memos.json as it starts, before anything can save; a stop flushes a pending change")
    func loadThenFlushOnStop() throws {
        let rig = try MemoRig()
        try rig.stateStore.saveMemos(memoBook())
        let session = try rig.session()
        let saver = try #require(session.store.memoSaver)
        #expect(session.store.state.memos == MemoBook() && !saver.isArmed, "nothing is loaded or armed before start")
        session.start()
        #expect(session.store.state.memos == memoBook())
        #expect(saver.isArmed)
        // A change on its way to disk (what `Store.dispatch` schedules for a memo action) is written as the session
        // stops, without waiting for the debounce.
        saver.schedule(memoBook("택배 반품"))
        session.stop()
        #expect(saver.saveCount == 1)
        #expect(try rig.stateStore.loadMemos().book == memoBook("택배 반품"))
    }

    @Test("A folder switch (a new session on another folder) reloads the memos and never writes an empty book")
    func folderSwitch() throws {
        let rig = try MemoRig()
        try rig.stateStore.saveMemos(memoBook())
        let old = try rig.session("Desk")
        old.start()
        old.store.memoSaver?.schedule(memoBook("from the old desk"))
        // AppDelegate.switchFolder: the old session stops (and saves), then the new one is made and started.
        old.stop()
        let new = try rig.session("Other")
        #expect(new.store.state.memos == MemoBook())
        new.store.flush()  // an unarmed saver writes nothing, so the empty book never reaches the file
        #expect(try rig.stateStore.loadMemos().book == memoBook("from the old desk"))
        new.start()
        #expect(new.store.state.memos == memoBook("from the old desk"))
        new.stop()
        #expect(new.store.memoSaver?.saveCount == 0, "nothing changed in the new session")
        #expect(try rig.stateStore.loadMemos().book == memoBook("from the old desk"))
    }

    @Test("A memos.json from a newer Deskterior: the session says memo changes are not saved, and never writes it")
    func newerFileToast() throws {
        let rig = try MemoRig()
        let file = rig.state.appendingPathComponent(StateStore.memosFileName)
        let future = Data("{\"schema\": 2, \"notes\": []}".utf8)
        try future.write(to: file)
        let session = try rig.session()
        session.start()
        #expect(session.host.scene.toastShown == .memosNotSaved)
        let saver = try #require(session.store.memoSaver)
        #expect(!saver.isArmed)
        let id = session.store.state.memos.nextNoteID
        session.store.dispatch(.addNote(NewNote(id: id, text: "새 메모", colour: .pink), session: nil))
        #expect(session.store.state.memos.notes[id] != nil)
        session.stop()
        #expect(saver.saveCount == 0)
        #expect(try Data(contentsOf: file) == future)
    }

    @Test("memos.json turning newer mid-session stops the saves, and the session says so")
    func newerMidSessionToast() async throws {
        let rig = try MemoRig()
        try rig.stateStore.saveMemos(memoBook())
        let session = try rig.session()
        session.start()
        #expect(session.host.scene.toastShown == nil)
        let file = rig.state.appendingPathComponent(StateStore.memosFileName)
        let future = Data("{\"schema\": 2, \"notes\": []}".utf8)
        try future.write(to: file)
        session.store.dispatch(.editNote(NoteID(1), text: "택배 반품", session: 1))
        session.store.flush()
        #expect(await eventually { session.host.scene.toastShown == .memosNotSaved })
        session.stop()
        #expect(try Data(contentsOf: file) == future)
    }

    @Test("A memo action dispatched to the store is scheduled; a replace (a load) never is")
    func dispatchSchedules() async throws {
        let rig = try MemoRig()
        let session = try rig.session()
        session.start()
        let saver = try #require(session.store.memoSaver)
        session.store.replace { $0.memos = memoBook() }
        session.store.flush()
        #expect(saver.saveCount == 0, "a replace is a load: not saved")
        let id = session.store.state.memos.nextNoteID
        session.store.dispatch(.addNote(NewNote(id: id, text: "새 메모", colour: .pink), session: nil))
        #expect(session.store.state.memos.notes[id] != nil)
        session.store.flush()
        #expect(saver.saveCount == 1)
        #expect(try rig.stateStore.loadMemos().book?.notes[id]?.text == "새 메모")
        session.stop()
    }
}
