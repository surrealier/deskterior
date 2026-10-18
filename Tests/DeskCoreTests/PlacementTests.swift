import Foundation
import Testing
@testable import DeskCore

@Suite("Placement")
struct PlacementTests {
    typealias F = ModelFixture

    @Test("Hints live 10 s, match NFC names and are used once")
    func hints() {
        var hints: [PlacementHint] = []
        let nfd = "사진.png".decomposedStringWithCanonicalMapping
        Placement.register([nfd: .floor(x: 7), "b.png": .floor(x: 8)], into: &hints, now: F.t0)
        #expect(hints.count == 2)
        #expect(Placement.takeHint(for: F.entry("사진.png", 1), from: &hints, now: F.t0 + 9.9) == .floor(x: 7))
        #expect(Placement.takeHint(for: F.entry("사진.png", 1), from: &hints, now: F.t0 + 1) == nil)
        #expect(Placement.takeHint(for: F.entry("b.png", 2), from: &hints, now: F.t0 + 10) == nil)
        // Re-registering a name replaces the old hint.
        Placement.register(["c.png": .floor(x: 1)], into: &hints, now: F.t0)
        Placement.register(["c.png": .floor(x: 2)], into: &hints, now: F.t0)
        #expect(hints.filter { $0.name == "c.png" }.count == 1)
        #expect(Placement.takeHint(for: F.entry("c.png", 3), from: &hints, now: F.t0) == .floor(x: 2))
    }

    @Test("Hints with an identity take only that file; name-only hints never fill the wastebasket")
    func hintIdentity() {
        var hints: [PlacementHint] = []
        let expires = F.t0 + 10
        Placement.register([
            PlacementHint(name: "moved.txt", location: .container(.phone, order: 0), expires: expires, key: F.key(5)),
            PlacementHint(name: "copied.txt", location: .container(.wastebasket, order: 0), expires: expires, size: 1),
            PlacementHint(name: "named.txt", location: .container(.wastebasket, order: 0), expires: expires),
        ], into: &hints)
        #expect(Placement.takeHint(for: F.entry("moved.txt", 6), from: &hints, now: F.t0) == nil)
        #expect(Placement.takeHint(for: F.entry("moved.txt", 5), from: &hints, now: F.t0) == .container(.phone, order: 0))
        var big = F.entry("copied.txt", 7)
        big.meta.size = 2
        #expect(Placement.takeHint(for: big, from: &hints, now: F.t0) == nil)
        #expect(Placement.takeHint(for: F.entry("copied.txt", 8), from: &hints, now: F.t0) == .container(.wastebasket, order: 0))
        #expect(Placement.takeHint(for: F.entry("named.txt", 9), from: &hints, now: F.t0) == nil)
    }

    @Test("Recent means 0…2 s before now; a clock that stepped back is not recent")
    func recency() {
        #expect(Placement.isRecent(F.t0, now: F.t0))
        #expect(Placement.isRecent(F.t0, now: F.t0 + 2))
        #expect(!Placement.isRecent(F.t0, now: F.t0 + 2.01))
        #expect(!Placement.isRecent(F.t0 + 3600, now: F.t0))
        #expect(!Placement.isRecent(nil, now: F.t0))
    }

    @Test("Expiry drops old hints and tombstones")
    func expiry() {
        var s = DeskState()
        Placement.register(["a": .floor(x: 0)], into: &s.hints, now: F.t0)
        s.tombstones = [
            Tombstone(key: F.key(1), name: "old", kind: .text, loc: .floor(x: 0), until: F.t0 + 5),
            Tombstone(key: F.key(2), name: "new", kind: .text, loc: .floor(x: 0), until: F.t0 + 50),
        ]
        #expect(Placement.expire(&s, now: F.t0 + 20) == 1)
        #expect(s.hints.isEmpty)
        #expect(s.tombstones.map(\.name) == ["new"])
    }

    @Test("Resolve keeps valid places and falls back sensibly")
    func resolve() {
        var s = F.mirrored(["a", "b"])
        var alloc = ScreenGrid.Allocator(grid: .standard, occupied: s.tokens.occupiedCells)
        // Occupied cell → nearest free on the same page.
        #expect(Placement.resolve(.screen(page: 0, col: 0, row: 0), in: &s, allocator: &alloc) == .screen(page: 0, col: 0, row: 1))
        // The cell just handed out is taken; the next nearest is diagonal (squared distance 2).
        #expect(Placement.resolve(.screen(page: 0, col: 0, row: 0), in: &s, allocator: &alloc) == .screen(page: 0, col: 1, row: 1))
        // Containers clamp the order; a full one falls back to the first free cell.
        #expect(Placement.resolve(.container(.phone, order: 4), in: &s, allocator: &alloc) == .container(.phone, order: 0))
        for i in 0..<6 { s.tokens.insert(F.key(UInt64(100 + i)), meta: TokenMeta(name: "p\(i)", kind: .text), at: .container(.phone, order: i)) }
        #expect(Placement.resolve(.container(.phone, order: 0), in: &s, allocator: &alloc) == .screen(page: 0, col: 2, row: 0))
        // A missing pile comes back only when its position is known.
        #expect(Placement.resolve(.desk(pile: "P4", order: 2), in: &s, allocator: &alloc) == .screen(page: 0, col: 3, row: 0))
        #expect(Placement.resolve(.desk(pile: "P4", order: 2), pilePos: [5, 6], in: &s, allocator: &alloc) == .desk(pile: "P4", order: 0))
        #expect(s.piles[PileID("P4")] == [5, 6])
        #expect(Placement.resolve(.floor(x: 33), in: &s, allocator: &alloc) == .floor(x: 33))
        #expect(Placement.resolve(.carried, in: &s, allocator: &alloc) == .screen(page: 0, col: 4, row: 0))
        #expect(Placement.resolve(nil, in: &s, allocator: &alloc) == .screen(page: 0, col: 5, row: 0))
    }

    @Test("Name order is Finder-like")
    func byName() {
        var s = DeskState()
        let names = ["b10", "B2", "a", "Ä1"]
        for (i, n) in names.enumerated() {
            s.tokens.insert(F.key(UInt64(i + 1)), meta: TokenMeta(name: n, kind: .text), at: .floor(x: i))
        }
        let ordered = Placement.byName(s.tokens.sortedKeys, in: s.tokens).map { s.tokens.meta(of: $0)!.name }
        #expect(ordered == ["a", "Ä1", "B2", "b10"])
    }

    @Test("Container specs follow DESIGN §2.2")
    func containerSpecs() {
        let caps = ContainerID.allCases.map { ($0, $0.spec.capacity, $0.spec.hardCap) }
        #expect(caps.map(\.1) == [8, 8, 12, 8, 12, 20, 6, 6, 24, 5])
        #expect(caps.map(\.2) == [14, 14, 12, 14, 18, 26, 6, 6, 24, 5])
        #expect(ContainerSpec.riserDrawer.closedLimit(count: 8) == 0)
        #expect(ContainerSpec.riserDrawer.closedLimit(count: 11) == 3)
        #expect(ContainerSpec.riserDrawer.closedLimit(count: 14) == 6)
        #expect(ContainerSpec.riserDrawer.isAtHardCap(14))
        #expect(ContainerID.riserCubby.spec.concealment == .partial)
        #expect(ContainerID.penCup.spec.concealment == .anonymized)
        #expect(ContainerID.allCases.filter(\.isDrawer).allSatisfy { $0.spec.travel != nil })
    }

    // MARK: tidy (0.3.0)

    @Test("awaySubstitute: the first shut, out, non-full concealing place; none for the shown memo clips")
    func awaySubstitute() {
        var s = ModelFixture.mirrored((1...20).map { "f\($0)" })
        s.stowed = [.cabinet]
        #expect(Placement.awaySubstitute(for: .cabinetTop, in: s) == .riserLeft)
        #expect(Placement.awaySubstitute(for: .memoClips, in: s) == nil, "a shown place's file stays in sight")
        // An open or peeking drawer is passed over, and so is a full one.
        s.drawers[.riserLeft] = DrawerState(p: 10)
        #expect(Placement.awaySubstitute(for: .cabinetFile, in: s) == .riserRight)
        s.drawers[.riserRight] = DrawerState(p: 1)
        s.phone.faceDown = true
        #expect(Placement.awaySubstitute(for: .cabinetFile, in: s) == .phone)
        s.drawers[.riserRight] = DrawerState()
        for i in 1...14 { s.tokens.move(ModelFixture.key(UInt64(i)), to: .container(.riserRight, order: 0)) }
        #expect(Placement.awaySubstitute(for: .cabinetMiddle, in: s) == .phone)
        // Away drawers are no stand-ins; a face-up phone hides nothing.
        s.stowed = [.cabinet, .riserDrawers]
        s.phone.faceDown = false
        #expect(Placement.awaySubstitute(for: .riserCubby, in: s) == nil)
        s.stowed = [.riserDrawers]
        #expect(Placement.awaySubstitute(for: .riserLeft, in: s) == .cabinetTop)
    }

    @Test("resolve sends a place that is put away to its stand-in, else the first free cell")
    func resolveAway() {
        var s = ModelFixture.mirrored(["a"])
        s.stowed = [.phoneStand, .partition]
        var alloc = ScreenGrid.Allocator(grid: .standard, occupied: s.tokens.occupiedCells)
        #expect(Placement.resolve(.container(.phone, order: 3), in: &s, allocator: &alloc) == .container(.riserLeft, order: 0))
        #expect(Placement.resolve(.container(.memoClips, order: 0), in: &s, allocator: &alloc) == .screen(page: 0, col: 1, row: 0))
        #expect(Placement.resolve(.container(.cabinetTop, order: 2), in: &s, allocator: &alloc) == .container(.cabinetTop, order: 0))
    }
}
