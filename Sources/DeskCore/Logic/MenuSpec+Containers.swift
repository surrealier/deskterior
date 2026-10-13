/// Container menus (DESIGN §2.2 E3–E5, §4.9).
extension MenuSpec {
    /// Names List Contents shows before "N More…" (which opens Find Item…).
    public static let listLimit = 20

    /// Right-click on a hiding place: Open/Close Drawer (Turn Face Up/Down for the phone), List Contents ▸ (every
    /// member by name; picking one flies it to the monitor), Move Contents to ▸ and Take All Out. Listing names is an
    /// explicit menu action, so it may show what the container hides (§2.1 non-destructive un-hiding). No key
    /// equivalents.
    public static func container(_ id: ContainerID, _ s: DeskState) -> MenuSpec {
        let members = s.tokens.members(of: id)
        let any = !members.isEmpty
        var items: [MenuItem] = []
        if id.isDrawer {
            items.append(s.drawerOpening(id) >= Visibility.drawerOpen
                ? MenuItem("close", "Close Drawer", .closeContainer(id))
                : MenuItem("open", "Open Drawer", .openContainer(id)))
            items.append(.separator)
        } else if id == .phone {
            items.append(s.phone.faceDown
                ? MenuItem("faceUp", "Turn Face Up", .openContainer(id))
                : MenuItem("faceDown", "Turn Face Down", .closeContainer(id)))
            items.append(.separator)
        }
        let monitor = firstFreeCell(s)
        let named = Placement.byName(members, in: s.tokens)
        var list = named.prefix(listLimit).enumerated().map { i, key in
            MenuItem("list.\(i)", s.tokens.meta(of: key)?.displayName ?? "?", .moveTo([key], monitor))
        }
        if named.count > listLimit {
            list.append(.separator)
            list.append(MenuItem("list.more", "\(named.count - listLimit) More…", .inventory))
        }
        items.append(MenuItem("listContents", "List Contents", submenu: list, enabled: any))
        // The token menu's Move to ▸, for every member, without the container itself.
        var moveTo: [MenuItem] = []
        if any, case let .submenu(children)? = token(members, s).item("moveTo")?.content {
            moveTo = children.filter { $0.id != "moveTo.\(id.rawValue)" }
        }
        items.append(MenuItem("moveTo", "Move Contents to", submenu: moveTo, enabled: any))
        items.append(.separator)
        items.append(MenuItem("takeAllOut", "Take All Out", .takeAllOut(id), enabled: any))
        return MenuSpec(items)
    }
}
