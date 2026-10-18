/// The desk partition's menus (Erratum 31): the bare felt, a note, the daily memo pad, the sticky-note cube, the
/// D-Day card, the clip light, the memo clips and the wall calendar. User text never appears in a title.
extension MenuSpec {
    /// Right-click on the bare felt, the frame or a post.
    public static func partition(_ s: DeskState, _ c: Context) -> MenuSpec {
        MenuSpec([]) // Step 0 stub: Track A (spec §5.5).
    }

    /// Right-click on a sticky note.
    public static func note(_ id: NoteID, _ s: DeskState) -> MenuSpec {
        MenuSpec([]) // Step 0 stub: Track A (spec §5.5).
    }

    /// Right-click on the daily memo pad.
    public static func dailyPad(_ s: DeskState, _ c: Context) -> MenuSpec {
        MenuSpec([]) // Step 0 stub: Track A (spec §5.5).
    }

    /// Right-click on the sticky-note cube.
    public static func cube(_ s: DeskState) -> MenuSpec {
        MenuSpec([]) // Step 0 stub: Track A (spec §5.5).
    }

    /// Right-click on the D-Day card.
    public static func dDayCard(_ s: DeskState) -> MenuSpec {
        MenuSpec([]) // Step 0 stub: Track A (spec §5.5).
    }

    /// Right-click on the clip light.
    public static func clipLight(_ s: DeskState) -> MenuSpec {
        MenuSpec([]) // Step 0 stub: Track A (spec §5.5).
    }

    /// Right-click on the wall calendar (`day`: the cell under the pointer, if any).
    public static func calendar(_ s: DeskState, _ c: Context, day: DayKey?) -> MenuSpec {
        MenuSpec([]) // Step 0 stub: Track A (spec §5.5).
    }

    /// What the memo clips' container menu ends with: a separator and Put Away Memo Clips (or Take Out %d & Put Away
    /// Memo Clips).
    public static func memoClipsExtras(_ s: DeskState) -> [MenuItem] {
        [] // Step 0 stub: Track A (spec §5.5).
    }
}
