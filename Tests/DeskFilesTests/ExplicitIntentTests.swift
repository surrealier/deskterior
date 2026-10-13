import DeskCore
import Foundation
import Testing
@testable import DeskFiles

@Suite("ExplicitIntent")
struct ExplicitIntentTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("An intent is fresh for 10 s and never from the future")
    func freshness() {
        func fresh(_ age: TimeInterval) -> Bool {
            ExplicitIntent(origin: .menuItem, issuedAt: now.addingTimeInterval(-age)).isFresh(at: now)
        }
        #expect(ExplicitIntent.maxAge == 10)
        #expect(fresh(0))
        #expect(fresh(9.9))
        #expect(fresh(10))
        #expect(!fresh(10.01))
        #expect(!fresh(3600))
        #expect(fresh(-0.5))
        #expect(!fresh(-5))
        let i = ExplicitIntent(origin: .drop, issuedAt: now)
        #expect(i.age(at: now.addingTimeInterval(3)) == 3)
        #expect(!i.isFresh(at: now.addingTimeInterval(3), maxAge: 2))
    }

    @Test("Every mutating FileOperator method refuses a stale intent and changes nothing",
          arguments: [TimeInterval(11), 600, -5])
    func staleRejected(age: TimeInterval) async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt", "desk")
        let b = try rig.file(rig.elsewhere, "b.txt", "drop")
        let key = rig.key(a)

        let trashed = await rig.op.trash([a], expecting: [key], rig.intent(age: age))
        #expect(trashed.outcomes == [.refused(a, .staleIntent)])
        #expect(trashed.undo == nil)

        let imported = await rig.op.importItems([b], op: .move, rig.intent(.drop, age: age))
        #expect(imported.outcomes == [.refused(b, .staleIntent)])

        // A real record, replayed with a stale intent.
        let fresh = await rig.op.trash([a], expecting: [key], rig.intent())
        let record = try #require(fresh.undo)
        let undone = await rig.op.undo(record, rig.intent(.undo, age: age))
        #expect(undone.refusals == [.staleIntent])
        #expect(rig.trashNames == ["a.txt"])

        #expect(await rig.op.eject(rig.desk, rig.intent(age: age)) == .refused(rig.desk, .staleIntent))

        #expect(rig.names(rig.desk).isEmpty)
        #expect(rig.text(b) == "drop")
        let outcomes = rig.log.entries().map(\.outcome)
        #expect(outcomes == ["refused: stale-intent", "refused: stale-intent", "ok", "refused: stale-intent",
                             "refused: stale-intent"])
    }

    @Test("Time moving on makes a held intent stale")
    func heldIntent() async throws {
        let rig = try FileRig()
        let a = try rig.file(rig.desk, "a.txt")
        let intent = rig.intent(.sheetConfirm)
        rig.clock.now = rig.clock.now.addingTimeInterval(30)
        let result = await rig.op.trash([a], expecting: [rig.key(a)], intent)
        #expect(result.refusals == [.staleIntent])
        #expect(rig.exists(a))
    }
}
