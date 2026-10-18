/// Put Away and Bring Back in the menus (Erratum 30): the desk and status menus' Put Away ▸ and Bring Back ▸, each
/// object's "Put Away ‹X›", and the sealed riser's menu.
extension MenuSpec {
    /// Right-click on the riser while its drawers are put away: Bring Back Riser Drawers, then the desk menu.
    public static func sealedRiser(_ s: DeskState, _ c: Context) -> MenuSpec {
        MenuSpec([]) // Step 0 stub: Track A (spec §5.5).
    }

    /// What an object's menu ends with: a separator and "Put Away %T", or "Take Out %d & Put Away %T" while it holds
    /// files (id `putAway`).
    public static func objectPutAway(_ id: StowID, _ s: DeskState) -> [MenuItem] {
        [] // Step 0 stub: Track A (spec §5.5).
    }
}
