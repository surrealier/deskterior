import Foundation
import Testing
@testable import DeskCore

@Suite("Reconciler")
struct ReconcilerTests {
    typealias F = ModelFixture

    @Test("A first snapshot places every file from HDMI 1 in name order")
    func firstSnapshot() {
        var s = DeskState()
        let snap = F.snapshot([F.entry("b.txt", 2), F.entry("a.txt", 1), F.entry("c.png", 3, kind: .image)])
        let events = Reconciler.reconcile(&s, snap, now: F.t0)
        #expect(s.root == DesktopRoot(path: F.rootPath, volume: F.volume))
        #expect(s.tokens.location(of: F.key(1)) == .screen(page: 0, col: 0, row: 0))
        #expect(s.tokens.location(of: F.key(2)) == .screen(page: 0, col: 1, row: 0))
        #expect(s.tokens.location(of: F.key(3)) == .screen(page: 0, col: 2, row: 0))
        #expect(events == [
            .added(F.key(1), .screen(page: 0, col: 0, row: 0), .new),
            .added(F.key(2), .screen(page: 0, col: 1, row: 0), .new),
            .added(F.key(3), .screen(page: 0, col: 2, row: 0), .new),
        ])
        #expect(s.violations().isEmpty)
        // The same snapshot again changes nothing.
        #expect(Reconciler.reconcile(&s, snap, now: F.t0.addingTimeInterval(1)).isEmpty)
    }

    @Test("A rename keeps the token and its place, even in a drawer")
    func renameKeepsLocation() {
        var s = F.mirrored(["a.txt", "b.txt"])
        s.tokens.move(F.key(2), to: .container(.cabinetTop, order: 0))
        let events = Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 1), F.entry("renamed.txt", 2)]), now: F.t0)
        #expect(events == [.renamed(F.key(2), from: "b.txt", to: "renamed.txt")])
        #expect(s.tokens.location(of: F.key(2)) == .container(.cabinetTop, order: 0))
        #expect(s.tokens.meta(of: F.key(2))?.name == "renamed.txt")
        #expect(s.tombstones.isEmpty)
    }

    @Test("Other metadata changes update the token in place")
    func metadataUpdate() {
        var s = F.mirrored(["a.txt"])
        var e = F.entry("a.txt", 1)
        e.meta.size = 999
        e.meta.tags = ["Red"]
        #expect(Reconciler.reconcile(&s, F.snapshot([e]), now: F.t0) == [.updated(F.key(1))])
        #expect(s.tokens.meta(of: F.key(1))?.tags == ["Red"])
    }

    @Test("Safe-save swap in one batch: same name, new inode keeps the place")
    func safeSaveSameBatch() {
        var s = F.mirrored(["doc.txt", "other.txt"])
        s.tokens.move(F.key(1), to: .container(.riserLeft, order: 0))
        let events = Reconciler.reconcile(&s, F.snapshot([F.entry("doc.txt", 77), F.entry("other.txt", 2)]), now: F.t0)
        #expect(events == [.rekeyed(from: F.key(1), to: F.key(77))])
        #expect(!s.tokens.contains(F.key(1)))
        #expect(s.tokens.location(of: F.key(77)) == .container(.riserLeft, order: 0))
        #expect(s.tombstones.isEmpty)
        #expect(s.violations().isEmpty)
    }

    @Test("Safe-save matching uses NFC names, so an NFD re-save still matches")
    func safeSaveNFD() {
        let nfc = "보고서 final.pdf"
        var s = F.mirrored([nfc], kind: .pdf)
        s.tokens.move(F.key(1), to: .container(.phone, order: 0))
        let nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(Array(nfd.unicodeScalars) != Array(nfc.unicodeScalars))
        let events = Reconciler.reconcile(&s, F.snapshot([F.entry(nfd, 5, kind: .pdf)]), now: F.t0)
        #expect(events == [.rekeyed(from: F.key(1), to: F.key(5))])
        #expect(s.tokens.location(of: F.key(5)) == .container(.phone, order: 0))
    }

    @Test("Safe-save across batches within 2 s is silent; later it is a tombstone restore")
    func safeSaveAcrossBatches() {
        var s = F.mirrored(["doc.txt", "x.txt"])
        s.tokens.move(F.key(1), to: .container(.cabinetFile, order: 0))
        let removed = Reconciler.reconcile(&s, F.snapshot([F.entry("x.txt", 2)]), now: F.t0)
        #expect(removed == [.removed(F.key(1), .container(.cabinetFile, order: 0), name: "doc.txt")])
        #expect(s.tombstones.count == 1)

        var quick = s
        let back = Reconciler.reconcile(
            &quick, F.snapshot([F.entry("doc.txt", 9), F.entry("x.txt", 2)]), now: F.t0.addingTimeInterval(1.5)
        )
        #expect(back == [.added(F.key(9), .container(.cabinetFile, order: 0), .safeSave)])
        #expect(quick.tombstones.isEmpty)

        var later = s
        let restored = Reconciler.reconcile(
            &later, F.snapshot([F.entry("doc.txt", 9), F.entry("x.txt", 2)]), now: F.t0.addingTimeInterval(60)
        )
        #expect(restored == [.added(F.key(9), .container(.cabinetFile, order: 0), .restored)])
    }

    @Test("A deleted file that comes back within 7 days returns to its hidden place")
    func tombstoneRestore() {
        var s = F.mirrored(["a.txt", "b.txt", "c.txt"])
        s.tokens.move(F.key(2), to: .container(.wastebasket, order: 0))
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 1), F.entry("c.txt", 3)]), now: F.t0)
        #expect(s.tombstones.map(\.key) == [F.key(2)])
        #expect(s.tombstones[0].until == F.t0.addingTimeInterval(7 * 24 * 3600))
        // A new file takes the first free cell meanwhile; the returning one still goes to the basket.
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 1), F.entry("c.txt", 3), F.entry("new.txt", 4)]), now: F.t0 + 10)
        let events = Reconciler.reconcile(
            &s, F.snapshot([F.entry("a.txt", 1), F.entry("b.txt", 2), F.entry("c.txt", 3), F.entry("new.txt", 4)]),
            now: F.t0.addingTimeInterval(3 * 24 * 3600)
        )
        #expect(events == [.added(F.key(2), .container(.wastebasket, order: 0), .restored)])
        #expect(s.tombstones.isEmpty)
    }

    @Test("Tombstones expire after 7 days")
    func tombstoneExpiry() {
        var s = F.mirrored(["a.txt", "b.txt"])
        s.tokens.move(F.key(2), to: .container(.penCup, order: 0))
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 1)]), now: F.t0)
        let events = Reconciler.reconcile(
            &s, F.snapshot([F.entry("a.txt", 1), F.entry("b.txt", 2)]), now: F.t0.addingTimeInterval(8 * 24 * 3600)
        )
        #expect(events == [.added(F.key(2), .screen(page: 0, col: 1, row: 0), .new)])
    }

    @Test("A pile that emptied comes back at its old desk position")
    func pileRestore() {
        var s = F.mirrored(["a.txt", "b.txt"])
        s.piles[PileID("P1")] = [100, 40]
        s.tokens.move(F.key(1), to: .desk(pile: "P1", order: 0))
        s.tokens.move(F.key(2), to: .desk(pile: "P1", order: 1))
        Reconciler.reconcile(&s, F.snapshot([]), now: F.t0)
        #expect(s.piles.isEmpty && s.tokens.isEmpty)
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 1), F.entry("b.txt", 2)]), now: F.t0 + 60)
        #expect(s.piles == [PileID("P1"): [100, 40]])
        #expect(s.tokens.members(of: PileID("P1")) == [F.key(1), F.key(2)])
        #expect(s.violations().isEmpty)
    }

    @Test("Display names are NFC; raw names are kept for matching")
    func nfdToNFC() {
        var s = DeskState()
        let nfd = "회의록.txt".decomposedStringWithCanonicalMapping
        Reconciler.reconcile(&s, F.snapshot([F.entry(nfd, 1)]), now: F.t0)
        let meta = s.tokens.meta(of: F.key(1))!
        #expect(meta.name == nfd)
        #expect(meta.name.unicodeScalars.count != meta.displayName.unicodeScalars.count)
        #expect(meta.displayName == "회의록.txt".precomposedStringWithCanonicalMapping)
    }

    @Test("Hints place our own files exactly; expired hints are ignored")
    func hints() {
        var s = F.mirrored(["a.txt"])
        Placement.register(["drop.png": .container(.riserRight, order: 0), "late.png": .screen(page: 0, col: 5, row: 3)], into: &s.hints, now: F.t0)
        let events = Reconciler.reconcile(
            &s, F.snapshot([F.entry("a.txt", 1), F.entry("drop.png", 2, kind: .image)]), now: F.t0.addingTimeInterval(3)
        )
        #expect(events == [.added(F.key(2), .container(.riserRight, order: 0), .hint)])
        #expect(s.hints.map(\.name) == ["late.png"])
        Reconciler.reconcile(
            &s, F.snapshot([F.entry("a.txt", 1), F.entry("drop.png", 2, kind: .image), F.entry("late.png", 3, kind: .image)]),
            now: F.t0.addingTimeInterval(11)
        )
        #expect(s.tokens.location(of: F.key(3)) == .screen(page: 0, col: 1, row: 0))
        #expect(s.hints.isEmpty)
    }

    @Test("A hint to an occupied cell lands on the nearest free cell")
    func hintToOccupiedCell() {
        var s = F.mirrored(["a.txt"])
        Placement.register(["b.txt": .screen(page: 0, col: 0, row: 0)], into: &s.hints, now: F.t0)
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 1), F.entry("b.txt", 2)]), now: F.t0)
        #expect(s.tokens.location(of: F.key(2)) == .screen(page: 0, col: 1, row: 0))
    }

    @Test("A burst of 200 files lays out in name order across pages")
    func burstOrder() {
        var s = DeskState()
        var rng = SplitMix64(seed: 7)
        var names = (0..<200).map { "unzipped \($0 + 1).txt" }
        for i in stride(from: names.count - 1, to: 0, by: -1) { names.swapAt(i, rng.nextInt(below: i + 1)) }
        let entries = names.enumerated().map { F.entry($0.element, UInt64(1000 + $0.offset)) }
        let events = Reconciler.reconcile(&s, F.snapshot(entries), now: F.t0)
        #expect(events.count == 200)
        let placedNames = events.map { e -> String in
            guard case let .added(k, _, .new) = e else { return "?" }
            return s.tokens.meta(of: k)!.name
        }
        #expect(placedNames == (1...200).map { "unzipped \($0).txt" })
        let cells = events.map { e -> ScreenCell in
            guard case let .added(_, loc, _) = e else { return ScreenCell(page: -1, col: 0, row: 0) }
            return loc.cell!
        }
        #expect(cells == cells.sorted())
        #expect(cells.last == ScreenCell(page: 4, col: 1, row: 2))
        #expect(s.pageCount() == 5)
        #expect(s.violations().isEmpty)
    }

    @Test("Removing files prunes trailing pages and clamps the current page")
    func pagePruning() {
        var s = DeskState()
        let entries = (0..<50).map { F.entry(String(format: "f%02d.txt", $0), UInt64($0 + 1)) }
        Reconciler.reconcile(&s, F.snapshot(entries), now: F.t0)
        s.monitor.page = 1
        #expect(s.pageCount() == 2)
        Reconciler.reconcile(&s, F.snapshot(Array(entries.prefix(40))), now: F.t0 + 1)
        #expect(s.pageCount() == 1)
        #expect(s.monitor.page == 0)
    }

    @Test("Hard links (duplicate keys) appear once")
    func duplicateKeys() {
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot([F.entry("a.txt", 1), F.entry("b.txt", 1)]), now: F.t0)
        #expect(s.tokens.count == 1)
    }

    @Test("A different folder starts a fresh layout")
    func rootChange() {
        var s = F.mirrored(["a.txt"])
        s.tokens.move(F.key(1), to: .container(.cabinetTop, order: 0))
        var snap = F.snapshot([F.entry("a.txt", 1)])
        snap.rootPath = "/elsewhere"
        let events = Reconciler.reconcile(&s, snap, now: F.t0)
        #expect(events.first == .reset)
        #expect(s.tokens.location(of: F.key(1)) == .screen(page: 0, col: 0, row: 0))
        #expect(s.root?.path == "/elsewhere")
    }

    @Test("A container at its hard cap sends a returning file to the monitor")
    func restoreIntoFullContainer() {
        var s = F.mirrored((0..<7).map { "p\($0).txt" })
        for i in 1...6 { s.tokens.move(F.key(UInt64(i)), to: .container(.penCup, order: 9)) }
        Reconciler.reconcile(&s, F.snapshot((1..<7).map { F.entry("p\($0).txt", UInt64($0 + 1)) }), now: F.t0)
        #expect(s.tokens.count(in: .penCup) == 5)
        s.tokens.move(F.key(7), to: .container(.penCup, order: 9))
        #expect(s.tokens.count(in: .penCup) == 6)
        Reconciler.reconcile(&s, F.snapshot((0..<7).map { F.entry("p\($0).txt", UInt64($0 + 1)) }), now: F.t0 + 60)
        #expect(s.tokens.location(of: F.key(1))?.isScreen == true)
        #expect(s.violations().isEmpty)
    }
}

/// Shared builders for model tests.
enum ModelFixture {
    static let volume = "VOL-1"
    static let rootPath = "/fake/Desktop"
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func key(_ inode: UInt64) -> TokenKey { TokenKey(volume: volume, inode: inode) }

    static func entry(_ name: String, _ inode: UInt64, kind: FileKind = .text) -> DesktopEntry {
        DesktopEntry(key: key(inode), meta: TokenMeta(name: name, kind: kind, added: t0, modified: t0, size: 1))
    }

    static func snapshot(_ entries: [DesktopEntry], at date: Date = t0) -> DesktopSnapshot {
        DesktopSnapshot(rootPath: rootPath, rootVolume: volume, entries: entries, scannedAt: date)
    }

    /// A state that has mirrored `names` (inodes 1…n) onto the screen.
    static func mirrored(_ names: [String], kind: FileKind = .text) -> DeskState {
        var s = DeskState()
        let entries = names.enumerated().map { entry($0.element, UInt64($0.offset + 1), kind: kind) }
        Reconciler.reconcile(&s, snapshot(entries), now: t0.addingTimeInterval(-3600))
        s.access = .connected
        return s
    }
}
