/// Put Away and Bring Back (Erratum 30): objects leave and return; files never stay inside a put-away place.
extension Reducer {
    /// `.putAway`, `.bringBack`, `.bringBackAll`, `.clipLight`.
    static func reduceTidy(_ s: inout DeskState, _ a: DeskAction, _ env: ReduceEnv) -> [Effect] {
        switch a {
        case let .putAway(id):
            return putAway(&s, id, grid: env.grid)
        case let .bringBack(id):
            // An add-on brings back the partition it hangs on.
            guard !s.isOut(id) else { return [] }
            return bringBack(&s, StowCatalog.lineage(of: id).filter { s.stowed.contains($0) }, puffs: [id])
        case .bringBackAll:
            let returning = s.stowed.sorted()
            guard !returning.isEmpty else { return [] }
            return bringBack(&s, returning, puffs: returning)
        case let .clipLight(on):
            // Not journaled, like the lamp; an away clip light keeps how it was set.
            guard s.isOut(.clipLight), s.clipLightOn != on else { return [] }
            s.clipLightOn = on
            return [.persist, .wakeLoop]
        default:
            return []
        }
    }

    /// Puts `id` away: the files in its hiding places (and its add-ons') parade to the monitor first, in this same
    /// step, as Take Everything Out does (`paradeToMonitor`); its drawers shut (empty now, so all the way); it leaves
    /// the room. The clip light keeps whether it is on. Nothing when it is not out.
    static func putAway(_ s: inout DeskState, _ id: StowID, grid: ScreenGrid) -> [Effect] {
        guard s.isOut(id) else { return [] }
        let keys = s.tokensInside(id)
        var effects = keys.isEmpty ? [] : paradeToMonitor(&s, keys, grid: grid)
        for c in ([id] + StowCatalog.children(of: id)).flatMap({ StowCatalog.spec($0).containers }) where c.isDrawer {
            s.drawers[c] = DrawerState(p: 0)
        }
        s.stowed.insert(id)
        effects.append(.play(.putAway, .stowable(id)))
        if !keys.isEmpty { effects.append(.toast(.tookFilesOut)) }
        return effects + [.persist, .wakeLoop]
    }

    /// `returning` leave the put-away set, and what rests where they stand moves aside in this same step, with one
    /// toast. A dust puff plays at each of `puffs`.
    private static func bringBack(_ s: inout DeskState, _ returning: [StowID], puffs: [StowID]) -> [Effect] {
        s.stowed.subtract(returning)
        let moved = makeRoom(for: returning, in: &s)
        var effects = puffs.map { Effect.play(.bringBack, .stowable($0)) }
        if moved { effects.append(.toast(.madeRoom)) }
        return effects + [.persist, .wakeLoop]
    }

    /// Moves aside what rests where `returning` objects stand, now that they are back (Erratum 30): the pen cup
    /// standing in a returning plant's or phone stand's footprint goes home, piles whose body meets that footprint
    /// go to the nearest valid desk spot (`PileWatchdog`; a pile with nowhere to go stays), floor tokens in a
    /// returning cabinet's span go to the nearest free floor spots, and notes a returning fixture would cover snap
    /// to a valid spot (`settleNotes`). The chair stays: it stands in front of the cabinet and blocks its drawers
    /// (E5). True when anything moved.
    static func makeRoom(for returning: [StowID], in s: inout DeskState) -> Bool {
        var moved = false
        let footprints = DeskPlanePhysics.footprints(stowed: s.stowed)
        let strips = returning.compactMap { StowCatalog.spec($0).footprint.flatMap { footprints[$0] } }
        if !strips.isEmpty {
            // Where the cup stood while they were away; it goes first, so the piles keep clear of its new place.
            let cup = PenCupMachine(s.penCup, stowed: s.stowed.union(returning))
            if strips.contains(where: { $0.intersects(cup.footprint) }), s.penCup.pos != PenCupState().pos {
                s.penCup.pos = PenCupState().pos
                moved = true
            }
            var watchdog = PileWatchdog()
            watchdog.stowed = s.stowed
            let obstacles = [DeskPlanePhysics.penCupFootprint(at: s.penCup.pos)]
            for pile in s.piles.keys.sorted() {
                guard let pos = s.piles[pile], pos.isFinite else { continue }
                let body = DeskPlaneRect.centred(at: pos, size: DeskPlanePhysics.pileSize)
                guard strips.contains(where: { $0.intersects(body) }) else { continue }
                let others = s.piles.filter { $0.key != pile }.map(\.value)
                guard let spot = watchdog.nearestValidSpot(to: pos, others: others, obstacles: obstacles) else {
                    continue
                }
                s.piles[pile] = spot
                moved = true
            }
        }
        for span in returning.compactMap({ StowCatalog.spec($0).floorSpan }) {
            var centres: [TokenKey: Int] = [:]
            for k in s.tokens.sortedKeys { if case let .floor(x)? = s.tokens.location(of: k) { centres[k] = x } }
            let half = FloorLine.tokenWidth / 2
            let blocked = centres.filter { span.overlaps(($0.value - half)..<($0.value + half)) }
            var placed = centres.filter { blocked[$0.key] == nil }.map(\.value)
            // Stack by stack, left to right, each to the free spots nearest where it stood.
            let stacks = Dictionary(grouping: blocked.keys.sorted(), by: { blocked[$0]! })
            for (x, keys) in stacks.sorted(by: { $0.key < $1.key }) {
                let spots = floorSpots(near: x, count: keys.count, basket: s.wastebasket, occupied: placed,
                                       stowed: s.stowed)
                for (k, spot) in zip(keys, spots) { s.tokens.move(k, to: .floor(x: spot)) }
                placed += spots
                moved = true
            }
        }
        // The partition and its add-ons, and the plant and phone stand in front of it.
        let fixtures = returning.contains {
            StowCatalog.lineage(of: $0).contains(.partition) || StowCatalog.spec($0).footprint != nil
        }
        if fixtures && settleNotes(&s) { moved = true }
        return moved
    }

    /// Notes that no longer rest validly (a returning fixture or a D-Day card that now shows covers them) snap to the
    /// nearest valid spot, else the first free one, back to front. Only while the partition is out. True when any
    /// moved.
    static func settleNotes(_ s: inout DeskState) -> Bool {
        guard s.isOut(.partition) else { return false }
        var moved = false
        for note in s.memos.backToFront where !PartitionLayout.isValidRest(note.pos, in: s) {
            let spot = PartitionLayout.snap(note.pos, in: s) ?? PartitionLayout.firstFreeSpot(in: s)
            guard spot != note.pos else { continue }
            s.memos.notes[note.id]?.pos = spot
            moved = true
        }
        return moved
    }
}
