import Testing
@testable import DeskCore

/// The room plan with things put away (Erratum 30) and the partition's placements (Erratum 31): what leaves the room
/// leaves only wall, desk or floor behind, with its shadows; decor goes through `SceneLayout.hiding`; the riser seals.
@Suite("Room plan: put away")
struct RoomPlanStowTests {
    let layout = LayoutSolver.solve(display: pixelGridDesignTable[0].display(dock: .hidden))
    static let day = WallTime(year: 2026, month: 10, day: 18, hour: 10, minute: 0)

    static func state(_ stowed: Set<StowID>, at time: WallTime = day) -> RoomState {
        var s = RoomState(time: time)
        s.stowed = stowed
        return s
    }

    static let partitionIDs = ["partition.panel", "partition.cube", "partition.pad", "partition.clips", "partition.dday",
                               "partition.clipLight"]

    /// The placements each object takes with it (decor aside).
    static let placementIDs: [StowID: Set<String>] = [
        .riserDrawers: ["riser.drawerL", "riser.drawerR"], .cabinet: ["cabinet"], .phoneStand: ["phone"],
        .plant: ["plant"], .partition: Set(partitionIDs), .dailyPad: ["partition.pad"],
        .memoClips: ["partition.clips"], .clipLight: ["partition.clipLight"], .dDayCard: ["partition.dday"],
    ]

    /// "decor.shelf.3" → `.shelf`.
    static func decorKind(_ id: String) -> WallDecor.Kind? {
        let parts = id.split(separator: ".")
        guard parts.count == 3, parts[0] == "decor" else { return nil }
        return WallDecor.Kind(rawValue: String(parts[1]))
    }

    @Test("The partition is the last of the backdrop, after the room switch, in its own order")
    func partitionOrder() throws {
        let plan = RoomPlan.placements(layout, Self.state([]))
        let ids = plan.map(\.id)
        let i = try #require(ids.firstIndex(of: "room.switch"))
        #expect(Array(ids[(i + 1)...(i + 6)]) == Self.partitionIDs)
        #expect(plan.last { $0.layer == .backdrop }?.id == "partition.clipLight")
        for p in plan where p.id.hasPrefix("partition.") {
            #expect(p.layer == .backdrop)
            #expect(p.origin == layout.point(CoreLayout.partition.origin) || p.id != "partition.panel")
        }
        #expect(plan.first { $0.id == "partition.pad" }?.rect == layout.rect(CoreLayout.partitionPad))
        #expect(plan.first { $0.id == "partition.clipLight" }?.rect == layout.rect(CoreLayout.partitionClipLight))
        #expect(plan.first { $0.id == "partition.clips" }?.rect == layout.rect(CoreLayout.partitionClips))
        // No D-Day: the card's placement is a blank stand-in, so a refresh can replace it.
        #expect(plan.first { $0.id == "partition.dday" }?.image.opaqueBounds() == .zero)
        var dated = Self.state([])
        dated.dDayDays = 12
        let card = RoomPlan.placements(layout, dated, only: ["partition.dday"])
        #expect(card.map(\.rect) == [layout.rect(CoreLayout.partitionDDay)])
    }

    @Test("Each object put away takes exactly its own placements and decor", arguments: StowID.allCases)
    func skips(_ id: StowID) {
        let all = RoomPlan.placements(layout, Self.state([]))
        let away = RoomPlan.placements(layout, Self.state([id]))
        let kinds = StowCatalog.spec(id).decorKinds
        let plain = Set(all.map(\.id).filter { Self.decorKind($0) == nil })
        let left = Set(away.map(\.id).filter { Self.decorKind($0) == nil })
        let children = StowCatalog.children(of: id).reduce(into: Set<String>()) { $0.formUnion(Self.placementIDs[$1] ?? []) }
        #expect(plain.subtracting(left) == (Self.placementIDs[id] ?? []).union(children), "\(id)")
        #expect(left.isSubset(of: plain))
        let decorBefore = all.compactMap { Self.decorKind($0.id) }, decorAfter = away.compactMap { Self.decorKind($0.id) }
        #expect(decorAfter == decorBefore.filter { !kinds.contains($0) }, "\(id)")
        if decorBefore.contains(where: kinds.contains) { #expect(decorAfter.count < decorBefore.count, "\(id)") }
    }

    @Test("An add-on keeps its flag while the partition is away; the partition brings them all")
    func addOns() {
        let ids = Set(RoomPlan.placements(layout, Self.state([.partition, .dailyPad])).map(\.id))
        #expect(ids.isDisjoint(with: Self.partitionIDs))
        let back = Set(RoomPlan.placements(layout, Self.state([.dailyPad])).map(\.id))
        #expect(back.isSuperset(of: Self.partitionIDs.filter { $0 != "partition.pad" }) && !back.contains("partition.pad"))
    }

    /// The pixels of `rect` no placement but the backdrop covers.
    static func bare(_ plan: [RoomPlacement], _ rect: ArtRect) -> [ArtPoint] {
        var out: [ArtPoint] = []
        for y in rect.minY..<rect.maxY {
            for x in rect.minX..<rect.maxX {
                let p = ArtPoint(x, y)
                let covered = plan.contains { pl in
                    pl.id != "backdrop" && pl.rect.contains(p) && pl.image.pixel(x - pl.origin.x, y - pl.origin.y).a != 0
                }
                if !covered { out.append(p) }
            }
        }
        return out
    }

    @Test("Put away, an object's pixels leave its place; what shows there is the backdrop or what stays",
          arguments: StowID.allCases)
    func leavesItsPlace(_ id: StowID) {
        var out = Self.state([])
        out.dDayDays = 5
        var state = out
        state.stowed = [id]
        let plan = RoomPlan.placements(layout, state)
        let room = RoomPlan.compose(layout, state), full = RoomPlan.compose(layout, out)
        let backdrop = RoomArt.backdrop(layout.hiding(StowCatalog.decorKinds(hiddenBy: [id])), stowed: [id])
        guard let anchor = StowCatalog.spec(id).anchor, let rect = layout.anchors[anchor] else {
            let shown = layout.decor.contains { StowCatalog.spec(id).decorKinds.contains($0.kind) }
            #expect((room != full) == shown, "\(id): its decor goes, if this Mac shows any")
            return
        }
        let r = rect.intersection(ArtRect(0, 0, room.width, room.height))
        #expect(room.cropped(to: r) != full.cropped(to: r), "\(id)")
        // (The felt behind an add-on and the sealed riser cover their places: there nothing is bare.)
        for p in Self.bare(plan, r) where room.pixel(p.x, p.y) != backdrop.pixel(p.x, p.y) {
            Issue.record("\(id) at \(p): not the backdrop")
        }
    }

    @Test("The plant, the phone stand and the cabinet leave bare desk, wall and floor, shadows included")
    func bareInks() {
        let wallDeskFloor: Set<RGBA8> = Set([Ink.neutral9, .neutral8, .neutral7, .neutral6, .neutral5, .neutral4, .oak0,
                                             .oak1, .oak2, .oak3, .oak4, .oak5, .walnut1].map(\.color))
        let cases: [(StowID, ArtRect, ArtRect)] = [
            // (object, its rect with its shadow, the shadow it no longer casts)
            (.plant, CoreLayout.plant.union(CoreLayout.plant.offsetBy(3, 2)), CoreLayout.plant.offsetBy(3, 2)),
            (.phoneStand, CoreLayout.phone.union(CoreLayout.phone.offsetBy(3, 2)), CoreLayout.phone.offsetBy(3, 2)),
            (.cabinet, ArtRect(390, 246, 90, 74), ArtRect(390, CoreLayout.floorY - 3, 90, 6)),
        ]
        for (id, rect, shadow) in cases {
            let stowed: Set<StowID> = [id, .partition]
            let room = RoomPlan.compose(layout, Self.state(stowed))
            let bare = RoomArt.backdrop(layout, stowed: stowed)
            let r = layout.rect(rect)
            #expect(room.cropped(to: r) == bare.cropped(to: r), "\(id): only the backdrop shows")
            #expect(Set(room.cropped(to: r).pixels).isSubset(of: wallDeskFloor), "\(id)")
            // The shadow went with it.
            let out = RoomArt.backdrop(layout, stowed: [.partition])
            #expect(out.cropped(to: layout.rect(shadow)) != bare.cropped(to: layout.rect(shadow)), "\(id) cast a shadow")
        }
        // The partition leaves the wall behind its tower (the monitor's shadow on it).
        let room = RoomPlan.compose(layout, Self.state([.partition]))
        let tower = layout.rect(CoreLayout.partitionTower)
        #expect(Set(room.cropped(to: tower).pixels).isSubset(of: [RoomArt.wall.color, RoomArt.wallShade.color]))
    }

    @Test("Backdrop shadows: each put-away object's shadow, and only it, leaves the backdrop")
    func backdropShadows() {
        let full = RoomArt.backdrop(layout)
        let regions: [(StowID, ArtRect)] = [
            (.plant, CoreLayout.plant.offsetBy(3, 2)), (.phoneStand, CoreLayout.phone.offsetBy(3, 2)),
            (.cabinet, ArtRect(390, CoreLayout.floorY - 3, 90, 6)),
            (.partition, CoreLayout.partitionTower.offsetBy(2, 2)),
        ]
        for (id, region) in regions {
            let away = RoomArt.backdrop(layout, stowed: [id])
            let r = layout.rect(region)
            var changed = 0
            for y in 0..<full.height {
                for x in 0..<full.width where full.pixel(x, y) != away.pixel(x, y) {
                    changed += 1
                    #expect(r.contains(ArtPoint(x, y)), "\(id): (\(x),\(y)) changed outside its shadow")
                }
            }
            #expect(changed > 0, "\(id)")
        }
        // Objects without a backdrop shadow leave it as it is (decor goes with the layout, not here).
        for id in [StowID.riserDrawers, .dailyPad, .memoClips, .clipLight, .dDayCard, .wallShelf] {
            #expect(RoomArt.backdrop(layout, stowed: [id]) == full, "\(id)")
        }
        // The desk surfaces are built once per subset and agree with the full table.
        #expect(RoomArt.deskSurface(skipping: []) == RoomArt.deskSurface)
        #expect(RoomArt.deskSurface(skipping: [.plant, .cabinet]) == RoomArt.deskSurface(skipping: [.plant]))
        // Through the plan, put-away decor takes its wall shadows too.
        let shelf = RoomPlan.placements(layout, Self.state([.wallShelf]), only: ["backdrop"])[0].image
        #expect(shelf == RoomArt.backdrop(layout.hiding([.shelf, .frame])) && shelf != full)
    }

    @Test("Put-away decor: the plan and the lit room both use the filtered layout")
    func decorFiltered() {
        for time in [Self.day, WallTime(year: 2026, month: 10, day: 18, hour: 22, minute: 0)] {
            var away = Self.state([.stringLights, .wallShelf, .pegboard], at: time)
            away.lightsMode = .lampOnly
            var plain = away
            plain.stowed = []
            let hidden = layout.hiding(StowCatalog.decorKinds(hiddenBy: away.stowed))
            #expect(RoomPlan.render(layout, away) == RoomPlan.render(hidden, plain))
            #expect(RoomPlan.render(hidden, away) == RoomPlan.render(layout, away), "hiding twice changes nothing")
            let kinds = Set(RoomPlan.placements(layout, away).compactMap { Self.decorKind($0.id) })
            #expect(kinds.isDisjoint(with: [.stringLights, .shelf, .frame, .pegboard]))
        }
    }

    @Test("The riser seals while its drawers are away")
    func sealedRiser() throws {
        let plan = RoomPlan.placements(layout, Self.state([.riserDrawers]))
        let riser = try #require(plan.first { $0.id == "riser" })
        #expect(riser.sprite.name == "riser.sealed" && riser.rect == layout.rect(CoreLayout.riser))
        let open = try #require(RoomPlan.placements(layout, Self.state([])).first { $0.id == "riser" })
        #expect(open.sprite.name == "riser")
        // Its front shows in the room below the monitor's stand.
        let room = RoomPlan.compose(layout, Self.state([.riserDrawers]))
        let r = layout.rect(CoreLayout.riser)
        let front = ArtRect(r.x, layout.y(CoreLayout.riserDrawerL.y), r.w, CoreLayout.riserDrawerL.h)
        #expect(room.cropped(to: front) == StorageArt.riser(sealed: true).image
            .cropped(to: front.offsetBy(-r.x, -r.y)))
    }

    @Test("Lights: the partition's lights only while it is out, the clip light only while it is, no phone glow away")
    func effectiveLights() {
        var s = Self.state([])
        s.lights.clipLightOn = true
        #expect(s.effectiveLights.partitionOut && s.effectiveLights.clipLightOn && s.effectiveLights.phoneFaceUp)
        s.lightsMode = .lampOnly
        #expect(s.effectiveLights.clipLightOn, "Lamp Only leaves the clip light as set")
        s.stowed = [.clipLight]
        #expect(s.effectiveLights.partitionOut && !s.effectiveLights.clipLightOn)
        s.stowed = [.partition]
        #expect(!s.effectiveLights.partitionOut && !s.effectiveLights.clipLightOn)
        s.stowed = [.phoneStand]
        #expect(!s.effectiveLights.phoneFaceUp && s.effectiveLights.clipLightOn)
        #expect(s.isOut(.clipLight) && !Self.state([.partition]).isOut(.dDayCard))
        // The clip light's sprite follows the effective light.
        var on = Self.state([])
        on.lights.clipLightOn = true
        let lit = RoomPlan.placements(layout, on, only: ["partition.clipLight"])
        #expect(lit.map(\.sprite.name) == ["partition.clipLight.on"])
    }

    @Test("Memo placements follow the memos: calendar marks, the written pad, the D-Day card")
    func memoPlacements() {
        var s = Self.state([])
        let ids = Set(RoomPlan.placements(layout, s, only: RoomPlan.memoIDs).map(\.id))
        #expect(ids == RoomPlan.memoIDs)
        #expect(RoomPlan.memoIDs.isSubset(of: RoomPlan.stateDependentIDs))
        #expect(RoomPlan.minuteIDs.isSuperset(of: ["partition.pad", "partition.dday"]))
        func image(_ id: String, _ s: RoomState) -> PixelBuffer {
            RoomPlan.placements(layout, s, only: [id])[0].image
        }
        let blank = (image("calendar", s), image("partition.pad", s), image("partition.dday", s))
        s.calendarMarks = [3: .memo]
        s.padWritten = true
        s.dDayDays = 4
        #expect(image("calendar", s) != blank.0 && image("calendar", s) == RoomArt.calendar(s.time, marks: [3: .memo]).image)
        #expect(image("partition.pad", s) != blank.1 && image("partition.dday", s) != blank.2)
        // Away, nothing to refresh.
        s.stowed = [.partition]
        #expect(Set(RoomPlan.placements(layout, s, only: RoomPlan.memoIDs).map(\.id)) == ["calendar"])
    }

    @Test("Other displays' walls put the same decor away (their own painting and floor plant too)")
    func wallArt() {
        let grid = PixelGrid(display: pixelGridDesignTable[1].display())
        let layout = LayoutSolver.solve(grid: grid)
        let all = WallArt.decor(layout)
        #expect(all.contains { $0.kind == .painting } && all.contains { $0.kind == .floorPlant })
        let away = WallArt.decor(layout, stowed: [.wallArt, .floorPlant, .stringLights])
        #expect(away.allSatisfy { ![.painting, .floorPlant, .stringLights].contains($0.kind) })
        #expect(away.count < all.count)
        var night = RoomState(time: WallTime(hour: 22, minute: 0))
        let before = WallArt.signature(grid: grid, state: night)
        night.stowed = [.cabinet]
        #expect(WallArt.signature(grid: grid, state: night) == before, "nothing on this wall changed")
        night.stowed = [.stringLights]
        #expect(WallArt.signature(grid: grid, state: night) != before)
        #expect(WallArt.render(grid: grid, state: night) != WallArt.render(grid: grid, state: RoomState(time: night.time)))
    }
}
