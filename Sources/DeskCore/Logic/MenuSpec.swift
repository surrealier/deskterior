/// Menus as data (DESIGN §4.9): token, monitor and bare-wall context menus and the status item are built from
/// the model here, so they are testable and scriptable by item id. The app turns a `MenuSpec` into an `NSMenu`
/// (`MenuBridge`) and runs the chosen `MenuCommand`: model commands become `DeskAction`s, the rest are app
/// commands (Inventory, Pause Desk, Quit…). There are no destructive key equivalents.
public struct MenuSpec: Sendable, Equatable {
    public var items: [MenuItem]

    public init(_ items: [MenuItem]) {
        self.items = items
    }

    /// The item with `id`, searching submenus depth first.
    public func item(_ id: String) -> MenuItem? {
        Self.find(id, in: items)
    }

    /// Every item id, submenus included, in menu order (separators excluded).
    public var ids: [String] {
        Self.flatten(items).filter { !$0.isSeparator }.map(\.id)
    }

    private static func find(_ id: String, in items: [MenuItem]) -> MenuItem? {
        for item in items {
            if item.id == id { return item }
            if case let .submenu(children) = item.content, let hit = find(id, in: children) { return hit }
        }
        return nil
    }

    private static func flatten(_ items: [MenuItem]) -> [MenuItem] {
        items.flatMap { item -> [MenuItem] in
            if case let .submenu(children) = item.content { return [item] + flatten(children) }
            return [item]
        }
    }
}

/// One menu row.
public struct MenuItem: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case command(MenuCommand)
        case submenu([MenuItem])
        case separator
    }

    /// Stable id ("open", "input.hdmi2", "lights.lamp"…) for tests and demo scripts.
    public var id: String
    public var title: String
    public var content: Content
    public var isEnabled: Bool
    public var isChecked: Bool

    public init(_ id: String, _ title: String, _ command: MenuCommand, enabled: Bool = true, checked: Bool = false) {
        self.id = id
        self.title = title
        content = .command(command)
        isEnabled = enabled
        isChecked = checked
    }

    public init(_ id: String, _ title: String, submenu: [MenuItem], enabled: Bool = true) {
        self.id = id
        self.title = title
        content = .submenu(submenu)
        isEnabled = enabled
        isChecked = false
    }

    public static let separator = MenuItem(separatorID: "-")

    private init(separatorID: String) {
        id = separatorID
        title = ""
        content = .separator
        isEnabled = false
        isChecked = false
    }

    public var isSeparator: Bool { content == .separator }

    public var command: MenuCommand? {
        if case let .command(c) = content { return c }
        return nil
    }
}

/// What a menu item does.
public enum MenuCommand: Sendable, Equatable {
    // Tokens
    case open([TokenKey])
    case quickLook([TokenKey])
    case reveal([TokenKey])
    case copy([TokenKey])
    /// Explicit, menu-only (no key equivalent); runs through `FileOperator` from M11.
    case moveToTrash([TokenKey])
    case moveTo([TokenKey], Location)
    case showOnDesk(TokenKey)

    // Monitor
    case power(Bool)
    case setPage(Int)
    case avInput
    case cleanUp(ScreenGrid.SortKey)

    // Lights
    case lightsMode(LightsMode)
    case roomLight(Bool)
    case deskLamp(Bool)

    // Desk
    case takeEverythingOut
    case clearDesk
    case emptyWastebasket
    case undo
    case redo

    // App
    case inventory
    case peekDesk
    case pauseDesk(Bool)
    case openDesktopFolder
    case settings
    case about
    case quit

    /// The model action this command dispatches; nil for app commands.
    public func action(_ s: DeskState) -> DeskAction? {
        switch self {
        case let .open(keys): .requestOpen(keys)
        case let .quickLook(keys): .requestQuickLook(keys)
        case let .reveal(keys): .requestReveal(keys)
        case let .copy(keys): .requestCopy(keys)
        case let .moveToTrash(keys): .requestTrash(keys)
        case let .moveTo(keys, to): .move(keys, to: to)
        case let .showOnDesk(key): .showOnDesk(key)
        case let .power(on): .power(on)
        case let .setPage(page): .setPage(page)
        case .avInput: .selectAV
        case let .cleanUp(order): .cleanUp(order)
        case let .lightsMode(mode): .lights(LightsState(mode: mode, room: s.lights.room, lamp: s.lights.lamp))
        case let .roomLight(on): .lights(LightsState(mode: s.lights.mode, room: on, lamp: s.lights.lamp))
        case let .deskLamp(on): .lights(LightsState(mode: s.lights.mode, room: s.lights.room, lamp: on))
        case .takeEverythingOut: .takeEverythingOut
        case .clearDesk: .clearDesk
        case .emptyWastebasket: .requestEmptyWastebasket
        case .undo: .undo
        case .redo: .redo
        case .inventory, .peekDesk, .pauseDesk, .openDesktopFolder, .settings, .about, .quit: nil
        }
    }
}

// MARK: - Builders

extension MenuSpec {
    /// What the desk and status menus show besides the model.
    public struct Context: Sendable, Equatable {
        public var paused: Bool
        /// "Move", "Take Everything Out"… (nil: nothing to undo).
        public var undo: String?
        public var redo: String?

        public init(paused: Bool = false, undo: String? = nil, redo: String? = nil) {
            self.paused = paused
            self.undo = undo
            self.redo = redo
        }
    }

    /// Commands whose milestone has not landed yet: shown, but disabled (each track removes its own).
    /// Move to Trash and Empty Wastebasket need `FileOperator` (M11), Clear the Desk the mat (M9), Peek Desk and
    /// Settings… their windows (M12).
    public static let pending: Set<String> = ["trash", "emptyWastebasket", "clearDesk", "peekDesk", "settings"]

    /// Right-click on tokens (the selection): open, look, reveal, copy, move to another page or a hiding place,
    /// trash.
    public static func token(_ keys: [TokenKey], _ s: DeskState) -> MenuSpec {
        let live = keys.filter { s.tokens.contains($0) }
        let any = !live.isEmpty
        let one = live.count == 1
        var moveTo: [MenuItem] = []
        let onScreen = live.allSatisfy { s.tokens.location(of: $0)?.isScreen == true }
        if !onScreen {
            moveTo.append(MenuItem("moveTo.monitor", "Monitor", .moveTo(live, Self.firstFreeCell(s)), enabled: any))
        } else if any {
            moveTo += pageItems(live, s)
        }
        moveTo.append(.separator)
        for id in ContainerID.allCases {
            let staying = s.tokens.members(of: id).filter { !live.contains($0) }.count
            let fits = staying + live.count <= id.spec.hardCap
            moveTo.append(MenuItem("moveTo.\(id.rawValue)", containerTitle(id),
                                   .moveTo(live, .container(id, order: s.tokens.count(in: id))), enabled: any && fits))
        }
        let name = one ? s.tokens.meta(of: live[0])?.displayName : nil
        return MenuSpec([
            MenuItem("open", "Open", .open(live), enabled: any),
            MenuItem("quickLook", name.map { "Quick Look “\($0)”" } ?? "Quick Look", .quickLook(live), enabled: any),
            MenuItem("reveal", "Show in Finder", .reveal(live), enabled: any),
            MenuItem("copy", "Copy", .copy(live), enabled: any),
            .separator,
            MenuItem("moveTo", "Move to", submenu: moveTo, enabled: any),
            .separator,
            MenuItem("trash", "Move to Trash", .moveToTrash(live), enabled: any && !pending.contains("trash")),
        ])
    }

    /// "Move to ▸ HDMI n" for tokens on the screen: every page in use and a new one after them. A page is offered
    /// when the tokens are not all on it already and it has room for them; they pour in from its first free cell.
    static func pageItems(_ keys: [TokenKey], _ s: DeskState, grid: ScreenGrid = .standard) -> [MenuItem] {
        let movers = Set(keys)
        let cells = s.tokens.occupiedCells
        return (0...s.pageCount(grid: grid)).map { page in
            let others = cells.filter { $0.page == page && !movers.contains(s.tokens.occupant(of: $0)!) }
            let here = keys.allSatisfy { s.tokens.location(of: $0)?.cell?.page == page }
            let fits = grid.cellsPerPage - others.count >= keys.count
            let aim = grid.firstFree(Set(others), fromPage: page)
            let title = page == s.pageCount(grid: grid) ? "HDMI \(page + 1) (New)" : "HDMI \(page + 1)"
            return MenuItem("moveTo.hdmi\(page + 1)", title, .moveTo(keys, aim.location), enabled: !here && fits)
        }
    }

    /// Menu names of the hiding places.
    public static func containerTitle(_ id: ContainerID) -> String {
        switch id {
        case .riserLeft: "Left Riser Drawer"
        case .riserRight: "Right Riser Drawer"
        case .riserCubby: "Riser Cubby"
        case .cabinetTop: "Top Cabinet Drawer"
        case .cabinetMiddle: "Middle Cabinet Drawer"
        case .cabinetFile: "File Drawer"
        case .penCup: "Pen Cup"
        case .phone: "Phone"
        case .wastebasket: "Wastebasket"
        }
    }

    /// Right-click on the monitor: power, inputs, Clean Up By (inputs only while on; Clean Up only on a desktop
    /// page).
    public static func monitor(_ s: DeskState) -> MenuSpec {
        let on = s.monitor.power == .on
        let pages = s.pageCount()
        let counts = Dictionary(grouping: s.tokens.occupiedCells, by: \.page).mapValues(\.count)
        var inputs = (0..<pages).map { p in
            MenuItem("input.hdmi\(p + 1)", "HDMI \(p + 1) · \(counts[p] ?? 0)", .setPage(p),
                     checked: !s.monitor.av && s.monitor.page == p)
        }
        inputs.append(MenuItem("input.av", "AV", .avInput, checked: s.monitor.av))
        let cleanUp = [
            MenuItem("cleanUp.name", "Name", .cleanUp(.name)),
            MenuItem("cleanUp.kind", "Kind", .cleanUp(.kind)),
            MenuItem("cleanUp.dateAdded", "Date Added", .cleanUp(.dateAdded)),
        ]
        return MenuSpec([
            MenuItem("power", on ? "Turn Display Off" : "Turn Display On", .power(!on)),
            .separator,
            MenuItem("input", "Input", submenu: inputs, enabled: on),
            MenuItem("cleanUp", "Clean Up By", submenu: cleanUp, enabled: on && !s.monitor.av && !s.tokens.occupiedCells.isEmpty),
        ])
    }

    /// The Lights submenu (Auto · Day · Night · Lamp Only · Room Light ✓ · Desk Lamp ✓).
    public static func lights(_ s: DeskState) -> [MenuItem] {
        let m = s.lights.mode
        return [
            MenuItem("lights.auto", "Auto", .lightsMode(.auto), checked: m == .auto),
            MenuItem("lights.day", "Day", .lightsMode(.day), checked: m == .day),
            MenuItem("lights.night", "Night", .lightsMode(.night), checked: m == .night),
            MenuItem("lights.lamp", "Lamp Only", .lightsMode(.lampOnly), checked: m == .lampOnly),
            .separator,
            MenuItem("lights.room", "Room Light", .roomLight(!s.lights.room), enabled: m != .lampOnly,
                     checked: s.lights.room && m != .lampOnly),
            MenuItem("lights.deskLamp", "Desk Lamp", .deskLamp(!s.lights.lamp), enabled: m != .lampOnly,
                     checked: s.lights.lamp || m == .lampOnly),
        ]
    }

    /// Right-click on the bare wall: the status item's menu, for when menu-bar extras are hidden (DESIGN §4.9).
    public static func desk(_ s: DeskState, _ c: Context = Context()) -> MenuSpec {
        MenuSpec(deskItems(s, c))
    }

    /// The menu-bar status item (the same items as the bare wall's menu).
    public static func status(_ s: DeskState, _ c: Context = Context()) -> MenuSpec {
        MenuSpec(deskItems(s, c))
    }

    private static func deskItems(_ s: DeskState, _ c: Context) -> [MenuItem] {
        let on = s.monitor.power == .on
        let hidden = s.tokens.keys { !$0.isScreen }.count
        let binned = s.tokens.count(in: .wastebasket)
        var items: [MenuItem] = [
            MenuItem("power", "Monitor Power", .power(!on), checked: on),
            MenuItem("lights", "Lights", submenu: lights(s)),
            .separator,
            MenuItem("find", "Find Item…", .inventory),
            MenuItem("takeEverythingOut", "Take Everything Out", .takeEverythingOut,
                     enabled: hidden > 0 || !on || s.monitor.av),
            MenuItem("clearDesk", "Clear the Desk", .clearDesk, enabled: !pending.contains("clearDesk")),
            MenuItem("peekDesk", "Peek Desk", .peekDesk, enabled: !pending.contains("peekDesk")),
            MenuItem("emptyWastebasket", binned > 0 ? "Empty Wastebasket… (\(binned))" : "Empty Wastebasket…",
                     .emptyWastebasket, enabled: binned > 0 && !pending.contains("emptyWastebasket")),
        ]
        items += [
            .separator,
            MenuItem("undo", c.undo.map { "Undo \($0)" } ?? "Undo", .undo, enabled: c.undo != nil),
            MenuItem("redo", c.redo.map { "Redo \($0)" } ?? "Redo", .redo, enabled: c.redo != nil),
            .separator,
            MenuItem("pause", c.paused ? "Resume Desk" : "Pause Desk", .pauseDesk(!c.paused)),
            MenuItem("openDesktopFolder", "Open Desktop Folder in Finder", .openDesktopFolder),
        ]
        items += [
            MenuItem("settings", "Settings…", .settings, enabled: !pending.contains("settings")),
            MenuItem("about", "About Deskterior", .about),
            .separator,
            MenuItem("quit", "Quit Deskterior", .quit),
        ]
        return items
    }

    /// Where "Move to ▸ Monitor" puts tokens: the first free cell from HDMI 1.
    static func firstFreeCell(_ s: DeskState) -> Location {
        ScreenGrid.standard.firstFree(s.tokens.occupiedCells).location
    }
}
