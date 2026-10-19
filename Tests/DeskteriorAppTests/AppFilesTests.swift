import AppKit
import DeskCore
import DeskFiles
import DeskScene
import Foundation
import Metal
import Testing
@testable import DeskFiles
@testable import DeskteriorApp

/// A monotonic clock a test holds still: an intent minted right after `hold()` stays fresh however long the whole
/// suite keeps the operator's call waiting, so a stale intent is a failure, never an excuse.
nonisolated final class HeldUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    /// Stops the clock just ahead of now (an intent minted within the next second or so is fresh by it).
    func hold() { lock.withLock { instant = .now + .milliseconds(500) } }

    var now: ContinuousClock.Instant { lock.withLock { instant } }
}

/// File actions on the test's own clock, confined to `desk`, `state` and a FakeTrash there (test mode).
@MainActor
func heldFileActions(desk: URL, state: URL, uptime: HeldUptime) throws -> FileActions {
    let scope = FileActionScope(mode: .test, folder: desk, stateDirectory: state)
    let log = try OperationLog(directory: state, desktop: desk, mirrored: desk)
    let trash = try FakeTrasher(folder: state.appendingPathComponent("FakeTrash"), desktop: desk, mirrored: desk)
    let op = FileOperator(root: desk, trasher: trash, log: log, sandboxRoots: scope.sandboxRoots,
                          uptime: { uptime.now })
    return FileActions(fileOperator: op, scope: scope)
}

/// A scene host, a store and an effect runner with a file operator confined to a scratch desk, its state folder and
/// a FakeTrash there (test mode: never the real Trash), as a session builds them.
@MainActor
final class AppRig {
    let temp: AppTemp
    let desk: URL
    let state: URL
    let host: SceneHost
    let store: Store
    let effects: EffectRunner
    let files: FileActions
    let dropIn: DropInController
    let uptime = HeldUptime()

    init() throws {
        temp = try AppTemp()
        desk = try temp.dir("Desk")
        state = try temp.dir("State")
        let device = try #require(MTLCreateSystemDefaultDevice())
        host = try SceneHost(grid: PixelGrid(display: DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2,
                                                                      topInsetPt: 33)), device: device)
        host.scene.setContent(.room)
        store = Store()
        effects = EffectRunner(host: host, folder: desk, dryRun: true)
        files = try heldFileActions(desk: desk, state: state, uptime: uptime)
        effects.files = files
        dropIn = DropInController(host: host, store: store, effects: effects)
        host.scene.apply(store.state)
    }

    /// The desk connected to `desk`.
    func connect() {
        store.replace {
            $0.root = DesktopRoot(path: desk.path, volume: FileOperator.volumeUUID(desk) ?? "v")
            $0.access = .connected
        }
    }

    var fakeTrash: URL { state.appendingPathComponent("FakeTrash") }

    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }
}

/// Polls `condition` every 20 ms until it holds, for at most `timeout` seconds of polling; it returns as soon as the
/// condition holds. A turn the main queue holds back (in a run that shares the main actor with hundreds of other
/// tests, a single one can last a quarter of an hour on a starved machine) counts at most 1 s, so main-queue work the
/// test waits for, queued behind the poller's wake-up, still runs before the last check; the wait ends after `timeout`
/// such turns at most. CI runs these tests one at a time (scripts/ci-test.sh), where a condition holds within seconds.
@MainActor
func eventually(_ timeout: Double = 60, _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    var left = Duration.seconds(timeout)
    while left > .zero, !Task.isCancelled {
        if condition() { return true }
        let turn = clock.now
        try? await Task.sleep(for: .milliseconds(20))
        left -= min(turn.duration(to: clock.now), .seconds(1))
    }
    return condition()
}

@Suite("App file paths", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct AppFilesTests {
    @Test("A file drag over a wall gets the desk's answer: nothing until connected, a move, or a copy (⌥, another volume)")
    func wallOperation() throws {
        let rig = try AppRig()
        let a = try rig.temp.file("Elsewhere/a.txt")
        #expect(rig.dropIn.wallOperation([a], copy: false, drag: 1) == [])
        rig.connect()
        #expect(rig.dropIn.wallOperation([a], copy: false, drag: 2) == .move)
        #expect(rig.dropIn.wallOperation([a], copy: true, drag: 2) == .copy)
        #expect(rig.dropIn.wallOperation([], copy: false, drag: 3) == [])
        let gone = rig.temp.root.appendingPathComponent("unreadable/b.txt")
        #expect(rig.dropIn.wallOperation([gone], copy: false, drag: 4) == .copy, "a volume that cannot be read copies")
    }

    @Test("Leftovers of an interrupted copy are logged and toasted once per session; an unchanged list is not news")
    func leftoversFound() throws {
        let rig = try AppRig()
        let leftover = try rig.temp.dir("Desk/.deskterior-partial-\(UUID().uuidString)")
        try rig.temp.file("Desk/\(leftover.lastPathComponent)/half.mov")
        let watch = LeftoverCopies(folder: rig.desk, host: rig.host)
        var heard: [[PartialCopies.Leftover]] = []
        watch.onChange = { heard.append($0) }
        // What a look finds off the main thread (`look()` hands it over on the main queue).
        let found = PartialCopies.find(in: rig.desk)
        watch.adopt(found)
        #expect(watch.found.map(\.url.lastPathComponent) == [leftover.lastPathComponent])
        #expect(heard.count == 1 && rig.host.scene.toastShown == .leftoverCopies)
        rig.host.scene.forceRest()
        #expect(rig.host.scene.toastShown == nil)
        watch.adopt(PartialCopies.find(in: rig.desk))
        #expect(rig.host.scene.toastShown == nil, "the toast is shown once per session")
        #expect(heard.count == 1, "an unchanged list is not news")
        watch.adopt([])
        #expect(heard.count == 2 && heard.last?.isEmpty == true && watch.found.isEmpty)
        #expect(rig.names(leftover) == ["half.mov"] && FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test("Leftovers go to the (fake) Trash only from the Settings button's menu gesture")
    func trashLeftovers() async throws {
        let rig = try AppRig()
        let leftover = try rig.temp.dir("Desk/.deskterior-partial-\(UUID().uuidString)")
        let items = PartialCopies.find(in: rig.desk)
        #expect(items.count == 1)
        var results: [FileResult?] = []
        rig.effects.trashLeftovers(items) { results.append($0) }
        rig.effects.withOrigin(.inventory) { rig.effects.trashLeftovers(items) { results.append($0) } }
        #expect(results.count == 2 && results.allSatisfy { $0 == nil }, "no gesture, or the wrong one: nothing runs")
        #expect(FileManager.default.fileExists(atPath: leftover.path))
        rig.uptime.hold()
        rig.effects.withOrigin(.menuItem) { rig.effects.trashLeftovers(items) { results.append($0) } }
        #expect(await eventually { results.count == 3 })
        let result = try #require(results.last ?? nil, "the button's gesture reached the operator")
        #expect(result.refusals.isEmpty, "a fresh intent on the held clock: the trash ran")
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(rig.names(rig.fakeTrash) == [leftover.lastPathComponent])
        #expect(PartialCopies.find(in: rig.desk).isEmpty)
    }

    @Test("A look lists the folder off the main thread; one asked for while it runs follows it, never dropped")
    func lookOffMain() async throws {
        let rig = try AppRig()
        let leftover = try rig.temp.dir("Desk/.deskterior-partial-\(UUID().uuidString)")
        let watch = LeftoverCopies(folder: rig.desk, host: rig.host)
        let threads = ThreadLog()
        watch.find = { folder in
            threads.note(Thread.isMainThread)
            return PartialCopies.find(in: folder)
        }
        watch.look()
        watch.look()  // while the first runs
        try #require(await eventually { watch.looks == 2 })
        #expect(threads.onMain == [false, false], "both listings ran off the main thread")
        #expect(watch.found.map(\.url.lastPathComponent) == [leftover.lastPathComponent])
        #expect(rig.host.scene.toastShown == .leftoverCopies)
    }
}

/// Where a stand-in finder ran.
nonisolated final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Bool] = []
    func note(_ main: Bool) { lock.withLock { log.append(main) } }
    var onMain: [Bool] { lock.withLock { log } }
}

/// A session over a scratch desk as desk mode starts one on a first run: not connected, so nothing reads the folder
/// before ⏻ (`connect`). Development stand-ins only: a temporary state folder, kind icons, no volumes.
@MainActor
final class SessionRig {
    let temp: AppTemp
    let desk: URL
    let state: URL
    let session: DeskSession

    init(connected: Bool = false, settings: DeskSettings = DeskSettings()) throws {
        temp = try AppTemp()
        desk = try temp.dir("Desk")
        state = try temp.dir("State")
        let home = try temp.dir("home")
        let desktop = try temp.dir("home/Desk")
        let options = try LaunchOptions.parse(["--windowed", "--desktop-folder", desk.path, "--state-dir", state.path,
                                               "--icons", "kind"])
        var configuration = try MirrorController.launch(options: options, environment: [:],
                                                        bundleID: AppIdentity.fallbackBundleID, settings: settings,
                                                        realDesktop: desktop, home: home).get()
        configuration.connectImmediately = connected
        configuration.finderHidesItems = false
        configuration.watchesVolumes = false
        let device = try #require(MTLCreateSystemDefaultDevice())
        let host = try SceneHost(grid: PixelGrid(display: DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2,
                                                                          topInsetPt: 33)), device: device)
        AppDelegate.configure(host, options)
        session = DeskSession(host: host, options: options, configuration: configuration, dryRun: true)
    }

    var fakeTrash: URL { state.appendingPathComponent("FakeTrash") }

    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }
}

@Suite("Leftover copies in a session", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct LeftoverSessionTests {
    @Test("The session looks for leftovers only once the mirror has read the folder: never before ⏻")
    func afterFirstSnapshot() async throws {
        let rig = try SessionRig()
        let leftover = try rig.temp.dir("Desk/.deskterior-partial-\(UUID().uuidString)")
        let session = rig.session
        defer { session.stop() }
        session.start()
        #expect(session.store.state.access == .notConnected)
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.mirror.snapshotCount == 0 && session.leftovers.looks == 0, "nothing read before ⏻")
        session.mirror.connect()  // what ⏻ (and the privacy prompt) leads to
        try #require(await eventually { session.leftovers.looks == 1 })
        #expect(session.mirror.snapshotCount >= 1)
        #expect(session.leftovers.found.map(\.url.lastPathComponent) == [leftover.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: leftover.path), "a look never changes anything")
    }

    @Test("Settings' Move to Trash: the button's gesture, the line it shows, and a fresh look; with none left, says so")
    func settingsButton() async throws {
        let rig = try SessionRig(connected: true)
        let leftover = try rig.temp.dir("Desk/.deskterior-partial-\(UUID().uuidString)")
        try rig.temp.file("Desk/\(leftover.lastPathComponent)/half.mov")
        let session = rig.session
        defer { session.stop() }
        let uptime = HeldUptime()
        session.effects.files = try heldFileActions(desk: rig.desk, state: rig.state, uptime: uptime)
        session.start()
        try #require(await eventually { session.leftovers.found.count == 1 })
        let model = SettingsModel(settings: DeskSettings(), lights: .auto, folderPath: rig.desk.path, folderLocked: true,
                                  displays: [])
        model.follow(session.leftovers)
        session.leftovers.onChange = { model.leftovers = $0.count }
        #expect(model.leftovers == 1)
        var notes: [String] = []
        uptime.hold()
        session.trashLeftovers { notes.append($0) }
        try #require(await eventually { notes.count == 1 })
        #expect(notes == [tr(.leftoversTrashed)])
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(rig.names(rig.fakeTrash) == [leftover.lastPathComponent])
        try #require(await eventually { session.leftovers.found.isEmpty && model.leftovers == 0 }, "a fresh look follows")
        session.trashLeftovers { notes.append($0) }
        #expect(notes.last == tr(.leftoversNone), "nothing to do is said, not silent")
    }

    @Test("After a folder switch Settings follows the new folder's leftovers, with no old note")
    func followsNewSession() throws {
        let old = try SessionRig()
        let new = try SessionRig()
        let model = SettingsModel(settings: DeskSettings(), lights: .auto, folderPath: old.desk.path, folderLocked: false,
                                  displays: [])
        model.follow(old.session.leftovers)
        model.leftovers = 2
        model.leftoverNote = "Moved to the Trash."
        model.follow(new.session.leftovers)
        #expect(model.leftovers == 0 && model.leftoverNote == nil)
    }
}
