import Foundation
import Testing
@testable import DeskCore

/// File identity across scans: which arrivals may take a remembered place (DESIGN §3.2).
@Suite("Reconciler identity")
struct IdentityTests {
    typealias F = ModelFixture

    func isNew(_ events: [DeskEvent], _ key: TokenKey) -> Bool {
        events.contains { if case .added(key, let loc, .new) = $0 { loc.isScreen } else { false } }
    }

    @Test("An unrelated file with a deleted file's name never lands in the wastebasket")
    func wastebasketNeedsTheSameFile() {
        let born = F.t0 - 86400
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot([F.entry("notes.txt", 1, created: born), F.entry("a.txt", 2)]), now: F.t0 - 60)
        s.tokens.move(F.key(1), to: .container(.wastebasket, order: 0))
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 2)]), now: F.t0)
        // Three days later: a new download, then even a same-size copy with the same creation date.
        let later = F.t0 + 3 * 86400
        var a = s
        let events = Reconciler.reconcile(&a, F.snapshot([F.entry("a.txt", 2), F.entry("notes.txt", 999)], at: later), now: later)
        #expect(isNew(events, F.key(999)))
        var b = s
        Reconciler.reconcile(&b, F.snapshot([F.entry("a.txt", 2), F.entry("notes.txt", 998, created: born)], at: later), now: later)
        #expect(b.tokens.location(of: F.key(998))?.isScreen == true)
        // Within the safe-save window too: only the same key goes back into the basket.
        var c = s
        Reconciler.reconcile(&c, F.snapshot([F.entry("a.txt", 2), F.entry("notes.txt", 997)], at: F.t0 + 1), now: F.t0 + 1)
        #expect(c.tokens.location(of: F.key(997))?.isScreen == true)
        var d = s
        Reconciler.reconcile(&d, F.snapshot([F.entry("a.txt", 2), F.entry("notes.txt", 1, created: born)], at: later), now: later)
        #expect(d.tokens.location(of: F.key(1)) == .container(.wastebasket, order: 0))
    }

    @Test("A safe-save swap in one batch keeps any place but the wastebasket")
    func sameBatchSwapSkipsWastebasket() {
        var s = F.mirrored(["doc.txt", "trash.txt"])
        s.tokens.move(F.key(1), to: .container(.phone, order: 0))
        s.tokens.move(F.key(2), to: .container(.wastebasket, order: 0))
        let events = Reconciler.reconcile(&s, F.snapshot([F.entry("doc.txt", 11), F.entry("trash.txt", 12)]), now: F.t0)
        #expect(events.contains(.rekeyed(from: F.key(1), to: F.key(11))))
        #expect(s.tokens.location(of: F.key(11)) == .container(.phone, order: 0))
        #expect(isNew(events, F.key(12)))
        #expect(s.tombstones.map(\.key) == [F.key(2)])
    }

    @Test("A launch scan is not one batch: a deleted and re-downloaded name is a new file")
    func launchScanIsNotABatch() {
        var s = F.mirrored(["invoice.pdf"], kind: .pdf)
        s.tokens.move(F.key(1), to: .container(.phone, order: 0))
        let later = F.t0 + 5 * 86400
        var a = s
        let events = Reconciler.reconcile(
            &a, F.snapshot([F.entry("invoice.pdf", 77, kind: .pdf)], at: later, continuous: false), now: later
        )
        #expect(!events.contains { if case .rekeyed = $0 { true } else { false } })
        #expect(isNew(events, F.key(77)))
        #expect(a.tombstones.first?.removedAt == nil)
        // Even a moment later the unknown removal time is not "recent".
        var b = s
        Reconciler.reconcile(&b, F.snapshot([], at: later, continuous: false), now: later)
        Reconciler.reconcile(&b, F.snapshot([F.entry("invoice.pdf", 78, kind: .pdf)], at: later + 1), now: later + 1)
        #expect(b.tokens.location(of: F.key(78))?.isScreen == true)
    }

    @Test("A launch scan still restores a copy whose size and creation date agree")
    func launchScanRestoresCorroboratedCopy() {
        let born = F.t0 - 86400
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot([F.entry("invoice.pdf", 1, kind: .pdf, created: born, size: 42)]), now: F.t0 - 60)
        s.tokens.move(F.key(1), to: .container(.phone, order: 0))
        let later = F.t0 + 86400
        let entry = F.entry("invoice.pdf", 77, kind: .pdf, created: born, size: 42)
        let events = Reconciler.reconcile(&s, F.snapshot([entry], at: later, continuous: false), now: later)
        #expect(events.contains(.added(F.key(77), .container(.phone, order: 0), .restored)))
        // A different size is a different file.
        var t = DeskState()
        Reconciler.reconcile(&t, F.snapshot([F.entry("invoice.pdf", 1, kind: .pdf, created: born, size: 42)]), now: F.t0 - 60)
        t.tokens.move(F.key(1), to: .container(.phone, order: 0))
        Reconciler.reconcile(&t, F.snapshot([F.entry("invoice.pdf", 77, kind: .pdf, created: born, size: 43)], at: later, continuous: false), now: later)
        #expect(t.tokens.location(of: F.key(77))?.isScreen == true)
    }

    @Test("A reused inode (kind and creation date both changed) is a removal plus a new file")
    func inodeReuse() {
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot([F.entry("secret.pdf", 1, kind: .pdf, created: F.t0 - 86400)]), now: F.t0 - 60)
        s.tokens.move(F.key(1), to: .container(.phone, order: 0))
        let events = Reconciler.reconcile(
            &s, F.snapshot([F.entry("holiday.png", 1, kind: .image, created: F.t0 + 5)], at: F.t0 + 10), now: F.t0 + 10
        )
        #expect(events.first == .removed(F.key(1), .container(.phone, order: 0), name: "secret.pdf"))
        #expect(isNew(events, F.key(1)))
        #expect(s.tokens.meta(of: F.key(1))?.name == "holiday.png")
        #expect(s.tokens.count(in: .phone) == 0)
        #expect(s.violations().isEmpty)
        // A rename that changes only the kind keeps the token.
        var r = DeskState()
        Reconciler.reconcile(&r, F.snapshot([F.entry("notes.txt", 1, kind: .text, created: F.t0 - 86400)]), now: F.t0 - 60)
        r.tokens.move(F.key(1), to: .container(.phone, order: 0))
        Reconciler.reconcile(&r, F.snapshot([F.entry("notes.md", 1, kind: .code, created: F.t0 - 86400)]), now: F.t0)
        #expect(r.tokens.location(of: F.key(1)) == .container(.phone, order: 0))
    }

    @Test("A mass vanish keeps hidden places over screen places, and is flagged for a confirming rescan")
    func massVanish() {
        let n = 2100
        var s = F.mirrored((0..<n).map { String(format: "f%05d.txt", $0) })
        for i in 1...10 { s.tokens.move(F.key(UInt64(i)), to: .container(.cabinetFile, order: 99)) }
        #expect(Reconciler.isMassRemoval(s, F.snapshot([])))
        #expect(!Reconciler.isMassRemoval(s, F.snapshot((0..<n - 30).map { F.entry(String(format: "f%05d.txt", $0), UInt64($0 + 1)) })))
        let cpu = TestSupport.cpuSeconds { Reconciler.reconcile(&s, F.snapshot([]), now: F.t0) }
        #expect(cpu < 1)
        #expect(s.tombstones.count == Tombstone.maxCount)
        #expect(s.tombstones.filter { $0.loc.container == .cabinetFile }.count == 10)
        let back = (0..<n).map { F.entry(String(format: "f%05d.txt", $0), UInt64($0 + 1)) }
        Reconciler.reconcile(&s, F.snapshot(back, at: F.t0 + 60), now: F.t0 + 60)
        #expect(s.tokens.count(in: .cabinetFile) == 10)
        #expect(s.violations().isEmpty)
    }

    @Test("A backup-style save seen half-way keeps the place (drawer, screen, rename-only)")
    func backupStyleSave() {
        // Scan 1 sees doc.txt~ (renamed) and the new doc.txt; scan 2 sees the backup gone.
        var s = F.mirrored(["doc.txt"])
        s.tokens.move(F.key(1), to: .container(.cabinetTop, order: 0))
        let first = Reconciler.reconcile(&s, F.snapshot([F.entry("doc.txt~", 1, kind: .unknown), F.entry("doc.txt", 2)]), now: F.t0)
        #expect(first.contains(.added(F.key(2), .screen(page: 0, col: 0, row: 0), .new)), "visible until proven a backup save")
        let gone = Reconciler.reconcile(&s, F.snapshot([F.entry("doc.txt", 2)], at: F.t0 + 0.3), now: F.t0 + 0.3)
        #expect(gone.contains(.moved(F.key(2), to: .container(.cabinetTop, order: 0))))
        #expect(s.tokens.location(of: F.key(2)) == .container(.cabinetTop, order: 0))
        #expect(s.violations().isEmpty)
        // If the renamed file stays, so does the newcomer (a Save As, not a backup save).
        var kept = F.mirrored(["doc.txt"])
        kept.tokens.move(F.key(1), to: .container(.cabinetTop, order: 0))
        Reconciler.reconcile(&kept, F.snapshot([F.entry("doc-v1.txt", 1), F.entry("doc.txt", 2)]), now: F.t0)
        Reconciler.reconcile(&kept, F.snapshot([F.entry("doc-v1.txt", 1), F.entry("doc.txt", 2)], at: F.t0 + 5), now: F.t0 + 5)
        Reconciler.reconcile(&kept, F.snapshot([F.entry("doc.txt", 2)], at: F.t0 + 6), now: F.t0 + 6)
        #expect(kept.tokens.location(of: F.key(2)) == .screen(page: 0, col: 0, row: 0))

        // On the screen the new file waits elsewhere, then takes over the cell.
        var t = F.mirrored(["a.txt", "doc.txt"])
        t.tokens.move(F.key(2), to: .screen(page: 0, col: 4, row: 2))
        Reconciler.reconcile(&t, F.snapshot([F.entry("a.txt", 1), F.entry("doc.txt~", 2), F.entry("doc.txt", 3)]), now: F.t0)
        #expect(t.tokens.location(of: F.key(3))?.isScreen == true)
        let second = Reconciler.reconcile(&t, F.snapshot([F.entry("a.txt", 1), F.entry("doc.txt", 3)], at: F.t0 + 0.3), now: F.t0 + 0.3)
        #expect(second.contains(.moved(F.key(3), to: .screen(page: 0, col: 4, row: 2))))
        #expect(t.tokens.location(of: F.key(3)) == .screen(page: 0, col: 4, row: 2))

        // Scan 1 sees only the rename; scan 2 sees the new file and the backup gone: a plain re-key.
        var u = F.mirrored(["doc.txt"])
        u.tokens.move(F.key(1), to: .container(.riserLeft, order: 0))
        Reconciler.reconcile(&u, F.snapshot([F.entry("doc.txt~", 1, kind: .unknown)]), now: F.t0)
        let events = Reconciler.reconcile(&u, F.snapshot([F.entry("doc.txt", 2)], at: F.t0 + 0.2), now: F.t0 + 0.2)
        #expect(events == [.rekeyed(from: F.key(1), to: F.key(2))])
        #expect(u.tokens.location(of: F.key(2)) == .container(.riserLeft, order: 0))
        // The memory is short: a rename long ago does not pull a new file in.
        var v = F.mirrored(["doc.txt"])
        v.tokens.move(F.key(1), to: .container(.riserLeft, order: 0))
        Reconciler.reconcile(&v, F.snapshot([F.entry("doc-old.txt", 1)]), now: F.t0)
        Reconciler.reconcile(&v, F.snapshot([F.entry("doc-old.txt", 1), F.entry("doc.txt", 2)], at: F.t0 + 30), now: F.t0 + 30)
        #expect(v.tokens.location(of: F.key(2))?.isScreen == true)
    }

    @Test("A clock that stepped back makes no removal recent")
    func clockSkew() {
        var s = F.mirrored(["x.txt"])
        s.tokens.move(F.key(1), to: .container(.riserLeft, order: 0))
        Reconciler.reconcile(&s, F.snapshot([], at: F.t0 + 3600), now: F.t0 + 3600)
        let events = Reconciler.reconcile(&s, F.snapshot([F.entry("x.txt", 5)]), now: F.t0)
        #expect(isNew(events, F.key(5)))
    }

    @Test("Hints come before safe-save swaps, and a name-only hint never fills the wastebasket")
    func hintsFirst() {
        var s = F.mirrored(["a.txt", "b.txt"])
        s.tokens.move(F.key(2), to: .container(.phone, order: 0))
        Placement.register(["b.txt": .floor(x: 40), "c.txt": .container(.wastebasket, order: 0)], into: &s.hints, now: F.t0)
        let events = Reconciler.reconcile(
            &s, F.snapshot([F.entry("a.txt", 1), F.entry("b.txt", 20), F.entry("c.txt", 30)], at: F.t0 + 1), now: F.t0 + 1
        )
        #expect(events.contains(.added(F.key(20), .floor(x: 40), .hint)))
        #expect(s.tokens.location(of: F.key(30))?.isScreen == true)
        #expect(s.hints.isEmpty == false)
    }

    @Test("A gesture that began before a safe-save still moves the token")
    func carriedThroughRekey() {
        var s = F.mirrored(["doc.txt", "b.txt"])
        _ = reduce(&s, .move([F.key(1)], to: .container(.phone, order: 0)), ReduceEnv(now: F.t0))
        _ = reduce(&s, .move([F.key(1)], to: .carried), ReduceEnv(now: F.t0))
        #expect(s.tokens.origin(of: F.key(1)) == .container(.phone, order: 0))
        let events = Reconciler.reconcile(&s, F.snapshot([F.entry("doc.txt", 9), F.entry("b.txt", 2)]), now: F.t0)
        #expect(events == [.rekeyed(from: F.key(1), to: F.key(9))])
        #expect(s.tokens.origin(of: F.key(9)) == .container(.phone, order: 0))
        #expect(s.currentKey(for: F.key(1)) == F.key(9))
        let effects = reduce(&s, .move([F.key(1)], to: .screen(page: 0, col: 5, row: 2)), ReduceEnv(now: F.t0))
        #expect(effects == [.persist, .wakeLoop])
        #expect(s.tokens.location(of: F.key(9)) == .screen(page: 0, col: 5, row: 2))
        #expect(s.tokens.origin(of: F.key(9)) == nil)
        #expect(s.violations().isEmpty)
    }

    @Test("A carried token that vanishes leaves a tombstone at its origin")
    func carriedVanish() {
        var s = F.mirrored(["a.txt", "b.txt"])
        s.tokens.move(F.key(1), to: .container(.riserRight, order: 0))
        s.tokens.move(F.key(1), to: .carried)
        let events = Reconciler.reconcile(&s, F.snapshot([F.entry("b.txt", 2)]), now: F.t0)
        #expect(events == [.removed(F.key(1), .container(.riserRight, order: 0), name: "a.txt")])
        #expect(s.tombstones.map(\.loc) == [.container(.riserRight, order: 0)])
    }

    @Test("A returning original takes its own place; no tombstone survives a live key")
    func returningOriginalBeatsImpostor() {
        var s = F.mirrored(["report.pdf"], kind: .pdf)
        s.tokens.move(F.key(1), to: .container(.phone, order: 0))
        Reconciler.reconcile(&s, F.snapshot([]), now: F.t0)
        Reconciler.reconcile(&s, F.snapshot([F.entry("draft.pdf", 2, kind: .pdf)], at: F.t0 + 10), now: F.t0 + 10)
        Reconciler.reconcile(&s, F.snapshot([F.entry("report.pdf", 2, kind: .pdf)], at: F.t0 + 20), now: F.t0 + 20)
        let events = Reconciler.reconcile(&s, F.snapshot([F.entry("report.pdf", 1, kind: .pdf)], at: F.t0 + 30), now: F.t0 + 30)
        #expect(events.contains(.added(F.key(1), .container(.phone, order: 0), .restored)))
        #expect(s.violations().isEmpty)
        #expect(s.tombstones.map(\.key) == [F.key(2)])
    }

    @Test("Pile ids are never reused while a tombstone remembers them")
    func pileIDsNotReused() {
        var s = F.mirrored(["a.txt", "b.txt"])
        _ = reduce(&s, .move([F.key(1)], to: .desk(pile: "P1", order: 0)), ReduceEnv(now: F.t0))
        _ = reduce(&s, .pilesSettled(["P1": [300, 70]]), ReduceEnv(now: F.t0))
        Reconciler.reconcile(&s, F.snapshot([F.entry("b.txt", 2)]), now: F.t0)
        let newPile = s.makePileID()
        #expect(newPile != PileID("P1"))
        _ = reduce(&s, .move([F.key(2)], to: .desk(pile: newPile, order: 0)), ReduceEnv(now: F.t0))
        _ = reduce(&s, .pilesSettled([newPile: [160, 20]]), ReduceEnv(now: F.t0))
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 1), F.entry("b.txt", 2)], at: F.t0 + 60), now: F.t0 + 60)
        #expect(s.tokens.location(of: F.key(1)) == .desk(pile: "P1", order: 0))
        #expect(s.piles[PileID("P1")] == [300, 70])
        #expect(s.tokens.members(of: newPile) == [F.key(2)])
    }

    @Test("An NFD → NFC respelling on disk updates the stored raw name")
    func respelling() {
        let nfd = "회의록.txt".decomposedStringWithCanonicalMapping
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot([F.entry(nfd, 1)]), now: F.t0)
        let nfc = nfd.precomposedStringWithCanonicalMapping
        let events = Reconciler.reconcile(&s, F.snapshot([F.entry(nfc, 1)]), now: F.t0 + 1)
        #expect(events == [.updated(F.key(1))])
        #expect(Array(s.tokens.meta(of: F.key(1))!.name.unicodeScalars) == Array(nfc.unicodeScalars))
    }

    @Test("File URLs need a current mirror and a plain name")
    func urls() {
        var s = F.mirrored(["a.txt"])
        #expect(s.url(of: F.key(1))?.path == F.rootPath + "/a.txt")
        s.access = .connecting
        #expect(s.url(of: F.key(1)) == nil)
        s.access = .connected
        // "a/\u{301}b": the slash hides inside one Character with its combining mark, so it is checked by scalar.
        for bad in ["../escape", "a/b", "..", ".", "", "a/\u{301}b"] {
            var meta = s.tokens.meta(of: F.key(1))!
            meta.name = bad
            s.tokens.updateMeta(F.key(1), meta)
            #expect(s.url(of: F.key(1)) == nil)
        }
    }

    // The bounds are about 10× this Mac's debug times (≈0.1 s each), in this thread's CPU time (a busy CI runner's waits
    // for a core do not count), so a slower runner passes while a quadratic slip, orders of magnitude slower, still
    // fails.
    @Test("Mass vanish and big moves stay fast at 5000 tokens")
    func performance() {
        let names = (0..<5000).map { String(format: "file %05d.txt", $0) }
        var s = F.mirrored(names)
        var cpu = TestSupport.cpuSeconds { Reconciler.reconcile(&s, F.snapshot([]), now: F.t0) }
        #expect(cpu < 1.0)
        Reconciler.reconcile(&s, F.snapshot(names.enumerated().map { F.entry($0.element, UInt64($0.offset + 1)) }, at: F.t0 + 5), now: F.t0 + 5)
        cpu = TestSupport.cpuSeconds {
            _ = reduce(&s, .move((1...1000).map { F.key(UInt64($0)) }, to: .screen(page: 3, col: 4, row: 2)), ReduceEnv(now: F.t0))
        }
        #expect(cpu < 1.0)
        #expect(s.violations().isEmpty)
    }
}
