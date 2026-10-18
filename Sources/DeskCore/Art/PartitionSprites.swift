/// The desk partition (Erratum 31): the felt panel and its tower, the sticky-note cube, the daily memo pad, the memo
/// clips, the D-Day card, the clip light and the notes themselves. Every placed sprite is the size of its
/// `CoreLayout` rect.
///
/// Step 0 stub: Track B. Every sprite here is blank (transparent) at its final size; nothing places them yet.
public enum PartitionArt {
    /// The low panel, the tower, the clamps and the cube's ledge (`partition.panel`, 488×108).
    public static func panel() -> SpriteAsset {
        blank("partition.panel", CoreLayout.partition.size) // Step 0 stub: Track B.
    }

    /// The sticky-note cube (`partition.cube`, 18×18).
    public static func cube() -> SpriteAsset {
        blank("partition.cube", CoreLayout.partitionCube.size) // Step 0 stub: Track B.
    }

    /// The daily memo pad for `day` (`partition.pad`, 38×44): the date header, the weekday, and rules or
    /// scribbles (`written`). The scene overlays today's first line.
    public static func dailyPad(_ day: WallTime, written: Bool) -> SpriteAsset {
        blank("partition.pad", CoreLayout.partitionPad.size) // Step 0 stub: Track B.
    }

    /// Frame `frame` (0..<3) of a page curling off the pad (34×26).
    public static func padPeel(_ frame: Int) -> SpriteAsset {
        blank("partition.padPeel.\(frame)", ArtSize(34, 26)) // Step 0 stub: Track B.
    }

    /// The memo-clip wire with five binder clips (`partition.clips`, 80×22).
    public static func clipsRail() -> SpriteAsset {
        blank("partition.clips", CoreLayout.partitionClips.size) // Step 0 stub: Track B.
    }

    /// A clipped file's card (14×16): paper, or a polaroid for an image; the scene blits the token's mini inside.
    public static func clipCard(image: Bool) -> SpriteAsset {
        blank(image ? "partition.card.image" : "partition.card", ArtSize(14, 16)) // Step 0 stub: Track B.
    }

    /// The D-Day card (`partition.dday`, 24×20) `days` before the D-Day (negative after it); nil (no D-Day) is
    /// `RoomPlan.blank`.
    public static func dDayCard(days: Int?) -> SpriteAsset {
        guard days != nil else { return RoomPlan.blank("partition.dday.none") }
        return blank("partition.dday", CoreLayout.partitionDDay.size) // Step 0 stub: Track B.
    }

    /// The clip light on the tower's top rail (`partition.clipLight`, 18×16).
    public static func clipLight(on: Bool) -> SpriteAsset {
        blank("partition.clipLight", CoreLayout.partitionClipLight.size) // Step 0 stub: Track B.
    }

    /// A note's paper (30×24) in `c`, with a date flag (`dated`) and a pushpin (`pinned`, odd ids) or tape. Text is
    /// not in the sprite.
    public static func notePaper(_ c: NoteColour, dated: Bool, pinned: Bool) -> SpriteAsset {
        blank("note.\(c.rawValue)", PartitionLayout.noteSize) // Step 0 stub: Track B.
    }

    /// Frame `frame` (0..<4) of a note balled up on its way into the wastebasket: 12×10, 10×9, 8×8, 6×6.
    public static func noteCrumple(_ c: NoteColour, frame: Int) -> SpriteAsset {
        let sizes = [ArtSize(12, 10), ArtSize(10, 9), ArtSize(8, 8), ArtSize(6, 6)]
        let size = sizes[min(max(frame, 0), sizes.count - 1)]
        return blank("note.crumple.\(c.rawValue).\(frame)", size) // Step 0 stub: Track B.
    }

    /// The D-Day card's text: "D-12" before the day, "D-DAY" on it, "D+3" after it (capped at 999).
    public static func ddayText(days: Int) -> String {
        if days > 0 { return "D-\(min(days, 999))" }
        if days == 0 { return "D-DAY" }
        return "D+\(-max(days, -999))"
    }

    private static func blank(_ name: String, _ size: ArtSize) -> SpriteAsset {
        SpriteAsset(name, PixelBuffer(width: size.w, height: size.h), anchor: .zero)
    }
}
