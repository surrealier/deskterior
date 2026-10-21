import Testing
@testable import DeskCore

/// The one table of what can be put away (Erratum 30) and the model questions built on it.
@Suite("StowCatalog")
struct StowCatalogTests {
    typealias F = ModelFixture

    @Test("Each hiding place has at most one owner: none for the pen cup and the wastebasket")
    func owners() {
        for c in ContainerID.allCases {
            let owners = StowID.allCases.filter { StowCatalog.spec($0).containers.contains(c) }
            #expect(owners.count <= 1, "\(c): \(owners)")
            #expect(StowCatalog.owner(of: c) == owners.first, "\(c)")
        }
        #expect(StowCatalog.owner(of: .penCup) == nil && StowCatalog.owner(of: .wastebasket) == nil)
        #expect(StowCatalog.owner(of: .riserCubby) == .riserDrawers && StowCatalog.owner(of: .cabinetFile) == .cabinet)
        #expect(StowCatalog.owner(of: .phone) == .phoneStand && StowCatalog.owner(of: .memoClips) == .memoClips)
        for c in ContainerID.allCases where c != .penCup && c != .wastebasket {
            #expect(StowCatalog.owner(of: c) != nil, "\(c) belongs to something that can be put away")
        }
    }

    @Test("Only the partition has add-ons; it hangs on nothing")
    func parents() {
        for id in StowID.allCases {
            let s = StowCatalog.spec(id)
            #expect(s.id == id)
            #expect(s.parent == nil || s.parent == .partition, "\(id)")
            #expect((s.parent == .partition) == (s.group == .partition && id != .partition), "\(id)")
        }
        #expect(StowCatalog.children(of: .partition) == [.dailyPad, .memoClips, .clipLight, .dDayCard])
        for id in StowID.allCases where id != .partition { #expect(StowCatalog.children(of: id).isEmpty, "\(id)") }
    }

    @Test("Wall decor goes in disjoint groups and never takes the architecture")
    func decorGroups() {
        var seen: Set<WallDecor.Kind> = []
        for id in StowID.allCases {
            let s = StowCatalog.spec(id)
            #expect(seen.isDisjoint(with: s.decorKinds), "\(id) shares decor")
            seen.formUnion(s.decorKinds)
            if s.group == .wall {
                #expect(!s.decorKinds.isEmpty && s.containers.isEmpty && s.anchor == nil && s.footprint == nil, "\(id)")
            } else {
                #expect(s.decorKinds.isEmpty && s.anchor != nil, "\(id)")
            }
        }
        #expect(seen.isDisjoint(with: [.ceiling, .crown, .rail, .pendant, .ceilingLamp]))
        #expect(StowCatalog.decorKinds(hiddenBy: [.wallShelf, .stringLights, .cabinet]) == [.shelf, .frame, .stringLights])
        #expect(StowCatalog.decorKinds(hiddenBy: []).isEmpty)
    }

    @Test("Object menus that end with Put Away: the riser, the cabinet, the phone and the plant")
    func elements() {
        #expect(StowCatalog.stowID(forElement: "riser") == .riserDrawers && StowCatalog.stowID(forElement: "cabinet") == .cabinet)
        #expect(StowCatalog.stowID(forElement: "phone") == .phoneStand && StowCatalog.stowID(forElement: "plant") == .plant)
        // MARK: picture frame (0.4.0): the framed print goes with the wall shelf (Erratum 33).
        #expect(StowCatalog.stowID(forElement: "frame") == .wallShelf)
        for other in ["pencup", "wastebasket", "lamp", "monitor", "keyboard", "chair", "hub", "calendar", "partition", "room"] {
            #expect(StowCatalog.stowID(forElement: other) == nil, "\(other)")
        }
    }

    @Test("The table names what physics, the floor line, knocks and anchors know, and translatable titles")
    func references() {
        let footprints = DeskPlanePhysics.footprints(stowed: [])
        for id in StowID.allCases {
            let s = StowCatalog.spec(id)
            if let f = s.footprint { #expect(footprints[f] != nil, "\(id): \(f)") }
            if let span = s.floorSpan { #expect(FloorLine.furniture.contains(span), "\(id)") }
            if let a = s.anchor { #expect(Anchors.core[a] != nil, "\(id): \(a)") }
            #expect(L10n.knows(s.title) && L10n.tr(s.title, .ko) != s.title, "\(s.title)")
        }
        #expect(StowCatalog.spec(.plant).wobbler == .plant && StowCatalog.spec(.phoneStand).wobbler == .phone)
        #expect(Set(StowID.allCases.map { StowCatalog.spec($0).title }).count == StowID.allCases.count)
        #expect(StowID.allCases.sorted() == StowID.allCases && StowID.riserDrawers < StowID.wallArt)
    }

    @Test("Away objects drop their footprint, floor span and decor; nothing is away by default")
    func awayGeometry() throws {
        let all = DeskPlanePhysics.footprints(stowed: [])
        #expect(Set(all.keys) == ["riser", "lamp", "plant", "phone", "hub"])
        #expect(Set(DeskPlanePhysics.footprints(stowed: [.plant, .phoneStand, .cabinet]).keys) == ["riser", "lamp", "hub"])
        #expect(DeskPlanePhysics.footprints(stowed: [.riserDrawers, .partition]) == all, "the riser stays as a stand")
        let cabinet = CoreLayout.cabinet.minX..<CoreLayout.cabinet.maxX
        #expect(FloorLine.furniture(basket: BasketState()) == FloorLine.furniture)
        #expect(!FloorLine.furniture(basket: BasketState(), stowed: [.cabinet]).contains(cabinet))
        #expect(FloorLine.furniture(basket: BasketState(), stowed: [.cabinet]).count == FloorLine.furniture.count - 1)
        var w = PileWatchdog()
        let plant = all["plant"]!
        let inPlant = SIMD2<Float>(plant.x + plant.width / 2, plant.d + plant.depth / 2)
        #expect(!w.isValidSpot(inPlant, others: []))
        w.stowed = [.plant]
        #expect(w.isValidSpot(inPlant, others: []), "a put-away plant leaves its strip free")
        let layout = LayoutSolver.solve(display: DisplayGeometry(widthPt: 1470, heightPt: 956, backingScale: 2, topInsetPt: 33))
        let kinds = Set(layout.decor.map(\.kind))
        let gone = try #require(kinds.first)
        let hidden = layout.hiding([gone])
        #expect(hidden.decor(gone).isEmpty && Set(hidden.decor.map(\.kind)) == kinds.subtracting([gone]))
        #expect(hidden.anchors == layout.anchors && hidden.grid == layout.grid && hidden.floorLift == layout.floorLift)
        #expect(hidden.hiding([gone]) == hidden && layout.hiding([]) == layout)
    }

    @Test("isOut follows the partition for its add-ons; isAway and tokensInside follow the containers")
    func stateQuestions() {
        var s = F.mirrored(["a.txt", "b.txt", "c.txt", "d.txt"])
        for id in StowID.allCases { #expect(s.isOut(id), "\(id) is out by default") }
        for c in ContainerID.allCases { #expect(!s.isAway(c), "\(c)") }
        s.tokens.move(F.key(1), to: .container(.cabinetFile, order: 0))
        s.tokens.move(F.key(2), to: .container(.cabinetTop, order: 0))
        s.tokens.move(F.key(3), to: .container(.memoClips, order: 0))
        s.tokens.move(F.key(4), to: .container(.penCup, order: 0))
        #expect(s.tokensInside(.cabinet) == [F.key(2), F.key(1)], "top drawer first")
        #expect(s.tokensInside(.partition) == [F.key(3)] && s.tokensInside(.memoClips) == [F.key(3)])
        #expect(s.tokensInside(.plant).isEmpty && s.tokensInside(.riserDrawers).isEmpty)
        s.stowed = [.partition]
        #expect(!s.isOut(.partition) && !s.isOut(.memoClips) && !s.isOut(.dDayCard) && s.isAway(.memoClips))
        #expect(!s.stowed.contains(.memoClips), "an add-on keeps its own flag")
        #expect(!s.isAway(.penCup) && !s.isAway(.cabinetTop))
        s.stowed = [.memoClips, .cabinet]
        #expect(s.isOut(.partition) && !s.isOut(.memoClips) && s.isOut(.dailyPad))
        #expect(s.isAway(.cabinetTop) && s.isAway(.cabinetMiddle) && s.isAway(.cabinetFile) && !s.isAway(.riserLeft))
    }

    @Test("Blockers: piles on a returning plant's strip, floor tokens in the cabinet's span")
    func blockers() {
        var s = F.mirrored(["a.txt", "b.txt"])
        for id in StowID.allCases { #expect(StowCatalog.blockers(of: id, in: s) == 0, "\(id)") }
        let plant = DeskPlanePhysics.footprints(stowed: [])["plant"]!
        s.tokens.move(F.key(1), to: .desk(pile: PileID("P1"), order: 0))
        s.piles[PileID("P1")] = SIMD2(plant.x + plant.width / 2, plant.d + 4)
        s.tokens.move(F.key(2), to: .floor(x: CoreLayout.cabinet.midX))
        #expect(StowCatalog.blockers(of: .plant, in: s) == 1 && StowCatalog.blockers(of: .phoneStand, in: s) == 0)
        #expect(StowCatalog.blockers(of: .cabinet, in: s) == 1 && StowCatalog.blockers(of: .riserDrawers, in: s) == 0)
        s.tokens.move(F.key(2), to: .floor(x: CoreLayout.cabinet.minX - 8))
        #expect(StowCatalog.blockers(of: .cabinet, in: s) == 0, "a token beside the cabinet's span is clear of it")
    }

    @Test("Memo clips are a shown place of five; a mini in sight; Find calls it Partition ▸ memo clips")
    func memoClips() {
        #expect(ContainerID.allCases.last == .memoClips && !ContainerID.memoClips.isDrawer)
        #expect(ContainerID.memoClips.spec == ContainerSpec(capacity: 5, hardCap: 5, concealment: .shown))
        let s = F.mirrored(["a.txt"])
        #expect(Visibility.of(.container(.memoClips, order: 0), s) == Visibility(.mini, hitTestable: true))
        #expect(!Visibility.of(.container(.memoClips, order: 0), s).isHidden)
        #expect(InventoryQuery.label(for: .memoClips) == "Partition ▸ memo clips")
        #expect(MenuSpec.containerTitle(.memoClips) == "Memo Clips")
        #expect(s.drawers[.memoClips] == nil)
    }
}
