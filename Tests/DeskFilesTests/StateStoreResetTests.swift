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

    @Test("Nothing saved: nothing to reset")
    func nothing() throws {
        let d = try TempDesk()
        let store = try StateStore(directory: d.url("state", isDirectory: true))
        #expect(try store.resetLayout() == nil)
        #expect(store.load().source == .fresh)
    }
}
