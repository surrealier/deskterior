/// Put Away and Bring Back in the menus (Erratum 30): the desk and status menus' Put Away ▸ and Bring Back ▸, each
/// object's "Put Away ‹X›", and the sealed riser's menu. Titles carry the object's English name in a `%T` template
/// ("Take Out 3 & Put Away Cabinet"), so `L10n.tr` translates them whole. Every item that takes files out says so.
extension MenuSpec {
    /// Right-click on the riser while its drawers are put away: Bring Back Riser Drawers, then the desk menu.
    public static func sealedRiser(_ s: DeskState, _ c: Context) -> MenuSpec {
        let title = "Bring Back \(StowCatalog.spec(.riserDrawers).title)"
        return MenuSpec([MenuItem("bringBack", title, .bringBack(.riserDrawers)), .separator] + deskItems(s, c))
    }

    /// What an object's menu ends with: a separator and "Put Away %T", or "Take Out %d & Put Away %T" while it holds
    /// files (id `putAway`). Nothing while it is not out.
    public static func objectPutAway(_ id: StowID, _ s: DeskState) -> [MenuItem] {
        guard s.isOut(id) else { return [] }
        return [.separator, MenuItem("putAway", putAwayTitle(id, s, named: true), .putAway(id))]
    }

    /// The desk and status menus' Put Away ▸ (what is out, in `StowCatalog` order, groups apart; an add-on only
    /// while the partition is out), Bring Back ▸ (what is away and can come back on its own, then Bring Everything
    /// Back; disabled, never hidden, when nothing is away) and Arrange Desk….
    static func tidyDeskItems(_ s: DeskState) -> [MenuItem] {
        let out = StowID.allCases.filter { s.isOut($0) }
        var putAway: [MenuItem] = []
        var group: StowSpec.Group?
        for id in out {
            let g = StowCatalog.spec(id).group
            if let group, group != g { putAway.append(.separator) }
            group = g
            putAway.append(MenuItem("putAway.\(id.rawValue)", putAwayTitle(id, s, named: false), .putAway(id)))
        }
        // An away partition is listed once: its add-ons come back with it.
        let away = StowID.allCases.filter {
            s.stowed.contains($0) && (StowCatalog.spec($0).parent.map(s.isOut) ?? true)
        }
        var bringBack = away.map { MenuItem("bringBack.\($0.rawValue)", StowCatalog.spec($0).title, .bringBack($0)) }
        if !bringBack.isEmpty { bringBack.append(.separator) }
        bringBack.append(MenuItem("bringBackAll", "Bring Everything Back", .bringBackAll, enabled: !away.isEmpty))
        return [
            MenuItem("putAway", "Put Away", submenu: putAway, enabled: !out.isEmpty),
            MenuItem("bringBack", "Bring Back", submenu: bringBack, enabled: !away.isEmpty),
            MenuItem("arrangeDesk", "Arrange Desk…", .arrangeDesk),
        ]
    }

    /// What putting `id` away is called: its name (or "Put Away ‹X›" when `named`), and "Take Out %d & Put Away
    /// ‹X›" while its places (and its add-ons') hold files, which go to the monitor first.
    static func putAwayTitle(_ id: StowID, _ s: DeskState, named: Bool) -> String {
        let title = StowCatalog.spec(id).title
        let n = s.tokensInside(id).count
        if n > 0 { return "Take Out \(n) & Put Away \(title)" }
        return named ? "Put Away \(title)" : title
    }
}
