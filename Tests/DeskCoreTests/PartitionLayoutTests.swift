import Testing
@testable import DeskCore

/// Where sticky notes rest on the desk partition (Erratum 31): the felt faces, the props in front, the fixtures, the
/// snap and the default spots.
@Suite("Partition layout")
struct PartitionLayoutTests {
    typealias L = PartitionLayout

    /// Every combination of the plant and the phone stand out or away, with and without a D-Day set.
    static var states: [DeskState] {
        var out: [DeskState] = []
        for stowed in [[], [StowID.plant], [.phoneStand], [.plant, .phoneStand]] as [Set<StowID>] {
            for dDay in [false, true] {
                var s = DeskState()
                s.stowed = stowed
                if dDay { s.memos.dDay = DDay(day: DayKey(year: 2026, month: 10, day: 30)!, title: "Exam") }
                out.append(s)
            }
        }
        return out
    }

    static func note(_ n: Int, at p: ArtPoint, z: Int = 0) -> StickyNote {
        StickyNote(id: NoteID(n), text: "", colour: .yellow, pos: p, z: z, created: ModelFixture.t0,
                   edited: ModelFixture.t0)
    }

    @Test("Geometry: the note, its text band, the felt faces inside the partition's rects")
    func geometry() {
        #expect(L.noteRect(at: ArtPoint(371, 67)) == ArtRect(371, 67, 30, 24))
        #expect(L.textBand(at: ArtPoint(371, 67)) == ArtRect(373, 71, 26, 12))
        #expect(L.noteRect(at: .zero).contains(L.textBand(at: .zero)))
        #expect(L.faces == [CoreLayout.partitionTowerFelt, CoreLayout.partitionFelt])
        #expect(CoreLayout.partitionTower.contains(CoreLayout.partitionTowerFelt))
        #expect(CoreLayout.partitionLow.contains(CoreLayout.partitionFelt))
        #expect(CoreLayout.partition.contains(CoreLayout.partitionLow.union(CoreLayout.partitionTower)))
        for r in [CoreLayout.partitionCube, CoreLayout.partitionPad, CoreLayout.partitionClips, CoreLayout.partitionDDay]
            + (0..<5).map(CoreLayout.memoClipCard) {
            #expect(CoreLayout.partitionFelt.contains(r) || CoreLayout.partitionLow.contains(r), "\(r)")
        }
        for i in 0..<5 { #expect(CoreLayout.partitionClips.contains(CoreLayout.memoClipCard(i))) }
    }

    @Test("Every default spot is valid with the plant and phone stand out or away (the last one only without a D-Day)",
          arguments: states)
    func defaultSpotsValid(_ s: DeskState) {
        for (i, p) in L.defaultSpots.enumerated() {
            let last = i == L.defaultSpots.count - 1
            #expect(L.isValidRest(p, in: s) == !(last && s.memos.dDay != nil), "\(p) with \(s.stowed)")
        }
        // No two default spots cover each other's text.
        for (i, a) in L.defaultSpots.enumerated() {
            for b in L.defaultSpots[(i + 1)...] { #expect(!L.textBand(at: a).intersects(L.noteRect(at: b))) }
        }
    }

    @Test("Behind the monitor, the riser, the plant or the hub, and off the felt, a note does not rest")
    func occludedSpotsInvalid() {
        let s = DeskState()
        // Behind the monitor's body, its stand and the riser.
        for p in [ArtPoint(200, 120), ArtPoint(250, 130), ArtPoint(200, 138), ArtPoint(300, 140)] {
            #expect(!L.isValidRest(p, in: s), "\(p)")
        }
        // The plant hides the left wing's lower half; put away, it no longer does (the cube still blocks low spots).
        #expect(!L.isValidRest(ArtPoint(36, 128), in: s))
        var away = s
        away.stowed = [.plant]
        #expect(L.isValidRest(ArtPoint(36, 128), in: away) && !L.isValidRest(ArtPoint(30, 132), in: away))
        // The hub sits at the felt's foot: a note low enough to be behind it would hang off the felt.
        #expect(!L.isValidRest(ArtPoint(406, 146), in: s))
        // Off the felt: over the rails, across the crossbar, past the posts.
        for p in [ArtPoint(14, 115), ArtPoint(15, 114), ArtPoint(468, 140), ArtPoint(466, 141), ArtPoint(371, 100),
                  ArtPoint(370, 67), ArtPoint(402, 67)] {
            #expect(!L.isValidRest(p, in: s), "\(p)")
        }
        // The lamp's rect covers the felt between the pad and the monitor.
        #expect(!L.isValidRest(ArtPoint(110, 120), in: s))
    }

    @Test("A note's text must show: 90 % of its band, 60 % of the note")
    func visibleShares() {
        let band = ArtRect(0, 0, 10, 10)
        #expect(L.visibleShare(of: band, past: []) == 1)
        #expect(L.visibleShare(of: band, past: [ArtRect(0, 0, 10, 1)]) == 0.9)
        // Overlapping occluders count once.
        #expect(L.hiddenPixels(of: band, behind: [ArtRect(0, 0, 5, 10), ArtRect(3, 0, 4, 10), ArtRect(2, 2, 2, 2)]) == 70)
        #expect(L.visibleShare(of: band, past: [ArtRect(-5, -5, 30, 30)]) == 0)
        // The phone stand's top edge hides the right wing's first column of notes low on the felt.
        let s = DeskState()
        #expect(!L.isValidRest(ArtPoint(372, 140), in: s))
        var away = s
        away.stowed = [.phoneStand]
        #expect(L.isValidRest(ArtPoint(372, 140), in: away), "the pen cup hides only its two columns")
    }

    @Test("Fixtures block a note while they are out: cube, pad, clips, clip light, a set D-Day card")
    func blockers() {
        var s = DeskState()
        #expect(L.blockers(s) == [CoreLayout.partitionCube, CoreLayout.partitionPad, CoreLayout.partitionClips,
                                  CoreLayout.partitionClipLight])
        #expect(!L.isValidRest(ArtPoint(20, 130), in: s), "over the cube")
        #expect(!L.isValidRest(ArtPoint(70, 120), in: s), "over the pad")
        #expect(!L.isValidRest(ArtPoint(400, 115), in: s), "over the clips")
        #expect(L.isValidRest(ArtPoint(464, 115), in: s), "where the D-Day card hangs, none set")
        s.memos.dDay = DDay(day: DayKey(year: 2026, month: 10, day: 30)!, title: "")
        #expect(L.blockers(s).contains(CoreLayout.partitionDDay) && !L.isValidRest(ArtPoint(464, 115), in: s))
        s.stowed = [.dDayCard, .memoClips, .dailyPad, .clipLight]
        #expect(L.blockers(s) == [CoreLayout.partitionCube])
        #expect(L.isValidRest(ArtPoint(464, 115), in: s) && L.isValidRest(ArtPoint(400, 115), in: s))
        #expect(L.isValidRest(ArtPoint(70, 117), in: s), "the pad put away frees its felt")
        // Everything comes back with the partition; the cube is the partition's own.
        s.stowed = [.partition]
        #expect(L.blockers(s) == [CoreLayout.partitionCube])
    }

    @Test("Occluders: the plant and the phone stand only while out; the pen cup where it stands")
    func occluders() {
        var s = DeskState()
        #expect(L.occluders(s).contains(CoreLayout.plant) && L.occluders(s).contains(CoreLayout.phone))
        #expect(L.occluders(s).contains(CoreLayout.penCup) && L.occluders(s).contains(PropArt.lampRect))
        s.stowed = [.plant, .phoneStand]
        #expect(!L.occluders(s).contains(CoreLayout.plant) && !L.occluders(s).contains(CoreLayout.phone))
        #expect(L.occluders(s).count == 6)
    }

    @Test("Snap: a valid drop stays, an invalid one moves to the nearest valid spot within 40 px, else nil")
    func snap() throws {
        let s = DeskState()
        for p in L.defaultSpots.dropLast() { #expect(L.snap(p, in: s) == p) }
        // Just over the right post: the nearest spot back on the felt.
        #expect(L.snap(ArtPoint(470, 140), in: s) == ArtPoint(466, 140))
        // Half off the tower's top: down onto it.
        #expect(L.snap(ArtPoint(380, 61), in: s) == ArtPoint(380, 67))
        // Over the clips: above them is the crossbar, so the nearest valid spot is below, or on the tower.
        let q = try #require(L.snap(ArtPoint(410, 118), in: s))
        #expect(L.isValidRest(q, in: s))
        let d2 = (q.x - 410) * (q.x - 410) + (q.y - 118) * (q.y - 118)
        #expect(d2 <= 40 * 40)
        // No nearer lattice point is valid.
        for o in L.snapOffsets where o.x * o.x + o.y * o.y < d2 {
            #expect(!L.isValidRest(ArtPoint(410 + o.x, 118 + o.y), in: s), "\(o)")
        }
        // Deep behind the monitor, nothing is within reach.
        #expect(L.snap(ArtPoint(250, 60), in: s) == nil)
        #expect(L.snapOffsets.first == .zero && L.snapOffsets.allSatisfy { $0.x % 2 == 0 && $0.y % 2 == 0 })
        #expect(L.snapOffsets.allSatisfy { $0.x * $0.x + $0.y * $0.y <= 1600 })
    }

    @Test("New notes take the first free valid default spot")
    func firstFree() {
        var s = DeskState()
        #expect(L.firstFreeSpot(in: s) == ArtPoint(371, 67))
        s.memos.notes[NoteID(1)] = Self.note(1, at: ArtPoint(371, 67))
        #expect(L.firstFreeSpot(in: s) == ArtPoint(401, 67))
        // A note a few px off a spot still takes it; one barely overlapping does not.
        s.memos.notes[NoteID(2)] = Self.note(2, at: ArtPoint(404, 70))
        #expect(L.firstFreeSpot(in: s) == ArtPoint(371, 88), "the tower's rows overlap by 3 px, not a quarter")
        for (i, p) in L.defaultSpots.enumerated() { s.memos.notes[NoteID(10 + i)] = Self.note(10 + i, at: p) }
        #expect(L.firstFreeSpot(in: s) == L.defaultSpots[0], "all taken: the first")
        // With a D-Day card, the last spot is never offered.
        var d = DeskState()
        d.memos.dDay = DDay(day: DayKey(year: 2026, month: 10, day: 30)!, title: "")
        for (i, p) in L.defaultSpots.dropLast().enumerated() { d.memos.notes[NoteID(1 + i)] = Self.note(1 + i, at: p) }
        #expect(L.firstFreeSpot(in: d) == L.defaultSpots[0])
        d.memos.dDay = nil
        #expect(L.firstFreeSpot(in: d) == L.defaultSpots.last)
    }

    @Test("Make-room counts notes a returning fixture would cover")
    func stowBlockers() {
        var s = DeskState()
        s.memos.notes[NoteID(1)] = Self.note(1, at: ArtPoint(30, 115))
        s.memos.notes[NoteID(2)] = Self.note(2, at: ArtPoint(371, 67))
        s.stowed = [.plant]
        #expect(StowCatalog.blockers(of: .plant, in: s) == 0)
        s.memos.notes[NoteID(3)] = Self.note(3, at: ArtPoint(36, 122))
        #expect(L.isValidRest(ArtPoint(36, 122), in: s))
        #expect(StowCatalog.blockers(of: .plant, in: s) == 1)
    }
}
