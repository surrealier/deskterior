import DeskCore
import Foundation
import Testing
@_spi(IntentMinting) @testable import DeskFiles

@Suite("ExplicitIntent")
struct ExplicitIntentTests {
    let now = ContinuousClock.now

    @Test("An intent is fresh for 10 s on the monotonic clock and never from the future")
    func freshness() {
        func fresh(_ age: Duration) -> Bool {
            ExplicitIntent(origin: .menuItem, issuedAt: Date(), instant: now - age).isFresh(at: now)
        }
        #expect(ExplicitIntent.maxAge == .seconds(10))
        #expect(fresh(.zero))
        #expect(fresh(.milliseconds(9900)))
        #expect(fresh(.seconds(10)))
        #expect(!fresh(.milliseconds(10010)))
        #expect(!fresh(.seconds(3600)))
        #expect(fresh(.milliseconds(-500)))
        #expect(!fresh(.seconds(-5)))
        let i = ExplicitIntent(origin: .drop, issuedAt: Date(), instant: now)
        #expect(i.age(at: now + .seconds(3)) == .seconds(3))
        #expect(!i.isFresh(at: now + .seconds(3), maxAge: .seconds(2)))
        // The wall-clock date plays no part: an intent stamped a day ago is fresh when it was issued just now.
        #expect(ExplicitIntent(origin: .drop, issuedAt: Date().addingTimeInterval(-86400), instant: now).isFresh(at: now))
    }

    @Test("The minting initializer stamps both clocks now and issues a new ledger entry each time")
    func minting() {
        let before = ContinuousClock.now
        let a = ExplicitIntent(origin: .menuItem)
        let b = ExplicitIntent(origin: .menuItem)
        #expect(a.origin == .menuItem)
        #expect(a.isFresh(at: .now))
        #expect(a.instant >= before)
        #expect(abs(a.issuedAt.timeIntervalSinceNow) < 5)
        #expect(a != b)
        #expect(IntentLedger.shared.spend(a.id))
        #expect(!IntentLedger.shared.spend(a.id))
        #expect(IntentLedger.shared.spend(b.id))
        #expect(!IntentLedger.shared.spend(UUID()))
    }

    @Test("Every mutating FileOperator method refuses a stale intent and changes nothing",
          arguments: [Double(11), 600, -5])
    func staleRejected(age: Double) async throws {
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
        rig.clock.advance(30)
        let result = await rig.op.trash([a], expecting: [rig.key(a)], intent)
        #expect(result.refusals == [.staleIntent])
        #expect(rig.exists(a))
    }
}
