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
        [] // Step 0 stub: Track B (spec §3.1).
    }

    /// Props in front of the felt that hide part of a note.
    public static func occluders(_ s: DeskState) -> [ArtRect] {
        [] // Step 0 stub: Track B (spec §3.1).
    }

    /// Whether a note may rest at `p`.
    public static func isValidRest(_ p: ArtPoint, in s: DeskState) -> Bool {
        false // Step 0 stub: Track B (spec §3.1).
    }

    /// The valid spot nearest `p` within 40 px (searched in 2-px rings), or nil.
    public static func snap(_ p: ArtPoint, in s: DeskState) -> ArtPoint? {
        nil // Step 0 stub: Track B (spec §3.1).
    }

    /// The first default spot no note takes (the first one when all are taken).
    public static func firstFreeSpot(in s: DeskState) -> ArtPoint {
        defaultSpots[0] // Step 0 stub: Track B (spec §3.1).
    }
}
