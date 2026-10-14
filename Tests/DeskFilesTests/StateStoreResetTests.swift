import DeskCore
import Foundation
import Testing
@testable import DeskFiles

/// Safe Mode's Reset Layout (M12): the saved layout is kept as a backup and a fresh desk keeps only the folder and the
/// lights; nothing else in the state folder goes away.
@Suite("StateStore reset")
struct StateStoreResetTests {
    @Test("Reset keeps desk.json as desk.reset-<date>.json and saves a fresh desk with the folder and the lights")
    func reset() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.url("state", isDirectory: true))
        var s = StateStoreTests.state(step: 4)
        let key = s.tokens.sortedKeys[0]
        _ = s.tokens.move(key, to: .container(.riserLeft, order: 0))
        s.lights = LightsState(mode: .night, room: false, lamp: true)
        s.monitor.power = .off
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(s, now: t0)
        let before = try Data(contentsOf: store.fileURL)

        let kept = try #require(try store.resetLayout(now: t0.addingTimeInterval(60)))
        #expect(kept.lastPathComponent == "desk.reset-20270115-080100.json")
        #expect(try Data(contentsOf: kept) == before, "the backup is the layout as it was")
        let fresh = try #require(store.load().document?.makeState())
        #expect(fresh.root == s.root && fresh.access == .connected, "the folder connects again at once")
        #expect(fresh.lights == s.lights)
        #expect(fresh.tokens.isEmpty && fresh.monitor.power == .on && fresh.flags.onboardingStep == 0)
        // A second reset the same second gets its own name; the first backup stays.
        let again = try #require(try store.resetLayout(now: t0.addingTimeInterval(60)))
        #expect(again != kept && FileManager.default.fileExists(atPath: kept.path))
    }

    @Test("The backup is the saved file byte for byte (formatting and all), not the layout re-encoded")
    func rawBackup() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.url("state", isDirectory: true))
        try store.save(StateStoreTests.state(step: 2))
        // As another build (or a person with a text editor) might have left it.
        let saved = try Data(contentsOf: store.fileURL)
        let edited = Data("\n  ".utf8) + saved + Data("\n\n".utf8)
        try edited.write(to: store.fileURL)
        #expect(store.load().source == .primary)
        let kept = try #require(try store.resetLayout())
        #expect(try Data(contentsOf: kept) == edited)
    }

    @Test("With a corrupt desk.json the backup keeps the file the desk would have loaded")
    func backupSource() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.url("state", isDirectory: true))
        try store.save(StateStoreTests.state(step: 3))
        try store.save(StateStoreTests.state(step: 4))
        let bak1 = try Data(contentsOf: store.backupURL(1))
        try Data("{\"schema\": 1, \"tokens\": 7".utf8).write(to: store.fileURL)
        #expect(store.load().source == .backup(1))
        let kept = try #require(try store.resetLayout())
        #expect(try Data(contentsOf: kept) == bak1)
    }

    @Test("Nothing saved: nothing to reset")
    func nothing() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.url("state", isDirectory: true))
        #expect(try store.resetLayout() == nil)
        #expect(store.load().source == .fresh)
    }
}
