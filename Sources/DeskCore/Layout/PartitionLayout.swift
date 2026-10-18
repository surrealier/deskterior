/// Where sticky notes may rest on the desk partition (Erratum 31), in core px. A note rests where its text band is at
/// least 90 % and the note at least 60 % visible past the props in front of the felt (`occluders`) and it meets no
/// fixture (`blockers`); a drop elsewhere snaps to the nearest valid spot within 40 px.
public enum PartitionLayout {
    public static let noteSize = ArtSize(30, 24)
    /// The felt a note can rest on: the tower's, then the low panel's.
    public static let faces: [ArtRect] = [CoreLayout.partitionTowerFelt, CoreLayout.partitionFelt]
    /// Where new notes go, in order (the first free one): four on the tower, three on the right wing, one on the left
    /// wing, and one where the D-Day card hangs (valid only while no card shows).
    public static let defaultSpots: [ArtPoint] = [
        ArtPoint(371, 67), ArtPoint(401, 67), ArtPoint(371, 88), ArtPoint(401, 88),
        ArtPoint(404, 140), ArtPoint(434, 140), ArtPoint(466, 140),
        ArtPoint(18, 115),
        ArtPoint(464, 115),
    ]
    /// The least share of the note, and of its text band, that must show past the props in front (in tenths).
    public static let minNoteVisibleTenths = 6
    public static let minTextVisibleTenths = 9
    /// How far a drop snaps, and the step of the rings it searches.
    public static let snapRadius = 40
    public static let snapStep = 2

    /// The note resting at `p` (its top-left).
    public static func noteRect(at p: ArtPoint) -> ArtRect {
        ArtRect(origin: p, size: noteSize)
    }

    /// The note's first line of text.
    public static func textBand(at p: ArtPoint) -> ArtRect {
        ArtRect(p.x + 2, p.y + 4, 26, 12)
    }

    /// Fixtures a note may not meet: the cube; the pad, the clips and the clip light while out; the D-Day card while
    /// out and set.
    public static func blockers(_ s: DeskState) -> [ArtRect] {
        var out = [CoreLayout.partitionCube]
        if s.isOut(.dailyPad) { out.append(CoreLayout.partitionPad) }
        if s.isOut(.memoClips) { out.append(CoreLayout.partitionClips) }
        if s.isOut(.clipLight) { out.append(CoreLayout.partitionClipLight) }
        if s.isOut(.dDayCard), s.memos.dDay != nil { out.append(CoreLayout.partitionDDay) }
        return out
    }

    /// Props in front of the felt that hide part of a note: the monitor and its stand, the riser, the lamp, the plant
    /// and the phone stand while out, the drive hub, and the pen cup where it stands (it is not stowable).
    public static func occluders(_ s: DeskState) -> [ArtRect] {
        var out = [CoreLayout.monitorBody, MonitorArt.standRect, CoreLayout.riser, PropArt.lampRect]
        if s.isOut(.plant) { out.append(CoreLayout.plant) }
        if s.isOut(.phoneStand) { out.append(CoreLayout.phone) }
        out.append(CoreLayout.driveHub)
        out.append(CoreLayout.penCup)
        return out
    }

    /// Whether a note may rest at `p`: on one felt face, clear of every fixture, its text band at least 90 % and the
    /// note at least 60 % in sight.
    public static func isValidRest(_ p: ArtPoint, in s: DeskState) -> Bool {
        isValidRest(p, blockers: blockers(s), occluders: occluders(s))
    }

    static func isValidRest(_ p: ArtPoint, blockers: [ArtRect], occluders: [ArtRect]) -> Bool {
        let note = noteRect(at: p)
        guard faces.contains(where: { $0.contains(note) }), !blockers.contains(where: { $0.intersects(note) }) else {
            return false
        }
        func shows(_ r: ArtRect, tenths: Int) -> Bool {
            10 * (r.w * r.h - hiddenPixels(of: r, behind: occluders)) >= tenths * r.w * r.h
        }
        return shows(textBand(at: p), tenths: minTextVisibleTenths) && shows(note, tenths: minNoteVisibleTenths)
    }

    /// The share (0…1) of `r`'s pixels that no rect in `occluders` covers.
    static func visibleShare(of r: ArtRect, past occluders: [ArtRect]) -> Double {
        1 - Double(hiddenPixels(of: r, behind: occluders)) / Double(r.w * r.h)
    }

    /// How many of `r`'s pixels the rects in `occluders` cover (overlapping occluders count once).
    static func hiddenPixels(of r: ArtRect, behind occluders: [ArtRect]) -> Int {
        let over = occluders.map { $0.intersection(r) }.filter { !$0.isEmpty }
        guard !over.isEmpty else { return 0 }
        var hidden = 0
        var spans: [(Int, Int)] = []
        for y in r.minY..<r.maxY {
            spans.removeAll(keepingCapacity: true)
            for o in over where o.minY <= y && y < o.maxY { spans.append((o.minX, o.maxX)) }
            guard !spans.isEmpty else { continue }
            spans.sort { $0.0 < $1.0 }
            var (start, end) = spans[0]
            for (a, b) in spans.dropFirst() {
                if a > end {
                    hidden += end - start
                    (start, end) = (a, b)
                } else {
                    end = max(end, b)
                }
            }
            hidden += end - start
        }
        return hidden
    }

    /// Offsets on the `snapStep` lattice within `snapRadius`, nearest first (ties: up before down, left before right),
    /// so the first valid one is the nearest valid spot.
    static let snapOffsets: [ArtPoint] = {
        let n = snapRadius / snapStep
        var out: [ArtPoint] = []
        for j in -n...n {
            for i in -n...n where i * i + j * j <= n * n { out.append(ArtPoint(i * snapStep, j * snapStep)) }
        }
        return out.sorted {
            let (a, b) = ($0.x * $0.x + $0.y * $0.y, $1.x * $1.x + $1.y * $1.y)
            return a != b ? a < b : ($0.y, $0.x) < ($1.y, $1.x)
        }
    }()

    /// The valid spot nearest `p` within 40 px (searched in 2-px rings), or nil.
    public static func snap(_ p: ArtPoint, in s: DeskState) -> ArtPoint? {
        let blockers = blockers(s), occluders = occluders(s)
        return snapOffsets.lazy.map { p + $0 }.first { isValidRest($0, blockers: blockers, occluders: occluders) }
    }

    /// The first default spot that is valid and that no note takes (a note covering a quarter of it takes it); the
    /// first spot when all are taken.
    public static func firstFreeSpot(in s: DeskState) -> ArtPoint {
        let blockers = blockers(s), occluders = occluders(s)
        let notes = s.memos.notes.values.map { noteRect(at: $0.pos) }
        let quarter = noteSize.w * noteSize.h / 4
        return defaultSpots.first { spot in
            let r = noteRect(at: spot)
            return isValidRest(spot, blockers: blockers, occluders: occluders)
                && !notes.contains { $0.intersection(r).size.area >= quarter }
        } ?? defaultSpots[0]
    }
}
