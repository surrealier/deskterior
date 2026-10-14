import AppKit
import DeskCore
import DeskFiles
import DeskScene
import Foundation
import Metal
import Testing
@testable import DeskteriorApp

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
        files = try FileActions(folder: desk, stateDirectory: state,
                                scope: FileActionScope(mode: .test, folder: desk, stateDirectory: state))
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

/// Polls `condition` until it holds or `timeout` passes (generous: the whole suite shares the main actor).
@MainActor
func eventually(_ timeout: Double = 120, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
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
        rig.effects.withOrigin(.menuItem) { rig.effects.trashLeftovers(items) { results.append($0) } }
        #expect(await eventually { results.count == 3 })
        let result = try #require(results.last ?? nil, "the button's gesture reached the operator")
        if result.refusals == [.staleIntent] {
            // The whole test suite can hold every thread of the concurrency pool past an intent's 10 s; then nothing
            // changed (the trash itself is covered on a test clock in `HardeningFileTests.trashLeftover`).
            #expect(FileManager.default.fileExists(atPath: leftover.path))
        } else {
            #expect(result.refusals.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: leftover.path))
            #expect(rig.names(rig.fakeTrash) == [leftover.lastPathComponent])
            #expect(PartialCopies.find(in: rig.desk).isEmpty)
        }
    }
}
