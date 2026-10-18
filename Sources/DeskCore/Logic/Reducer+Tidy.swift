/// Put Away and Bring Back (Erratum 30): objects leave and return; files never stay inside a put-away place.
extension Reducer {
    /// `.putAway`, `.bringBack`, `.bringBackAll`, `.clipLight`.
    static func reduceTidy(_ s: inout DeskState, _ a: DeskAction, _ env: ReduceEnv) -> [Effect] {
        [] // Step 0 stub: Track A (spec §5.2: putAway, bringBack, bringBackAll, makeRoom, clipLight).
    }
}
