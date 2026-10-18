/// Sticky notes, the day pages and the D-Day (Erratum 31). Memo actions emit no `.persist`: `MemoSaver` follows
/// `state.memos`.
extension Reducer {
    /// `.addNote`, `.editNote`, `.noteColour`, `.noteDay`, `.moveNote`, `.raiseNote`, `.removeNote`, `.editDayPage`,
    /// `.tearOffPage`, `.setDDay`.
    static func reduceMemos(_ s: inout DeskState, _ a: DeskAction, _ env: ReduceEnv) -> [Effect] {
        [] // Step 0 stub: Track A (spec §5.2).
    }
}
