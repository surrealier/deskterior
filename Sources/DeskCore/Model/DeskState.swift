import Foundation

/// A live token: what it is and where it lives.
public struct TokenRecord: Sendable, Equatable {
    public var meta: TokenMeta
    public var location: Location

    public init(meta: TokenMeta, location: Location) {
        self.meta = meta
        self.location = location
    }
}

/// Membership of every live token, with the indexes that keep the model invariants cheap to hold:
/// one location per token, at most one token per screen cell, and dense `0..<n` orders inside each container
/// and pile. Mutations that would break an invariant are refused (they return false and change nothing).
public struct TokenStore: Sendable, Equatable {
    public private(set) var records: [TokenKey: TokenRecord] = [:]
    private var cells: [ScreenCell: TokenKey] = [:]
    private var groups: [Location.Group: [TokenKey]] = [:]

    public init() {}

    public var count: Int { records.count }
    public var isEmpty: Bool { records.isEmpty }
    /// Keys in ascending order (deterministic iteration).
    public var sortedKeys: [TokenKey] { records.keys.sorted() }

    public subscript(key: TokenKey) -> TokenRecord? { records[key] }
    public func contains(_ key: TokenKey) -> Bool { records[key] != nil }
    public func location(of key: TokenKey) -> Location? { records[key]?.location }
    public func meta(of key: TokenKey) -> TokenMeta? { records[key]?.meta }

    public var occupiedCells: Set<ScreenCell> { Set(cells.keys) }
    public func occupant(of cell: ScreenCell) -> TokenKey? { cells[cell] }

    /// Container members in order.
    public func members(of id: ContainerID) -> [TokenKey] { groups[.container(id)] ?? [] }
    /// Pile members in order (bottom first).
    public func members(of pile: PileID) -> [TokenKey] { groups[.pile(pile)] ?? [] }
    public func count(in id: ContainerID) -> Int { members(of: id).count }
    /// Piles holding at least one token.
    public var piles: [PileID] {
        groups.keys.compactMap { if case let .pile(p) = $0 { p } else { nil } }.sorted()
    }

    /// Keys whose location satisfies `filter`, in ascending key order.
    public func keys(where filter: (Location) -> Bool) -> [TokenKey] {
        sortedKeys.filter { filter(records[$0]!.location) }
    }

    /// True when `location` can take one more token: a free, in-grid cell; a container below its hard cap;
    /// any pile, floor spot or carry.
    public func canAccept(_ location: Location, grid: ScreenGrid = .standard) -> Bool {
        switch location {
        case let .screen(page, col, row):
            let c = ScreenCell(page: page, col: col, row: row)
            return grid.contains(c) && cells[c] == nil
        case let .container(id, _):
            return count(in: id) < id.spec.hardCap
        case .desk, .floor, .carried:
            return true
        }
    }

    /// Adds a new token. Container and pile orders are clamped to `0...count` and later members shift up.
    @discardableResult
    public mutating func insert(_ key: TokenKey, meta: TokenMeta, at location: Location, grid: ScreenGrid = .standard) -> Bool {
        guard records[key] == nil, canAccept(location, grid: grid) else { return false }
        records[key] = TokenRecord(meta: meta, location: location)
        attach(key, location)
        return true
    }

    /// Removes a token; later members of its container or pile shift down.
    @discardableResult
    public mutating func remove(_ key: TokenKey) -> TokenRecord? {
        guard let record = records[key] else { return nil }
        detach(key, record.location)
        return records.removeValue(forKey: key)
    }

    /// Moves a token. Moving within the same container or pile reorders it. Refused when the target cannot
    /// take it (occupied cell, full container).
    @discardableResult
    public mutating func move(_ key: TokenKey, to location: Location, grid: ScreenGrid = .standard) -> Bool {
        guard let record = records[key] else { return false }
        if record.location == location { return true }
        let sameGroup = record.location.group != nil && record.location.group == location.group
        if !sameGroup {
            guard canAccept(location, grid: grid) else { return false }
        }
        detach(key, record.location)
        records[key]!.location = location
        attach(key, location)
        return true
    }

    public mutating func updateMeta(_ key: TokenKey, _ meta: TokenMeta) {
        records[key]?.meta = meta
    }

    /// Gives a token a new identity in place (safe-save swap): same location, same order.
    @discardableResult
    public mutating func rekey(_ old: TokenKey, to new: TokenKey, meta: TokenMeta) -> Bool {
        guard old != new, records[new] == nil, let record = records.removeValue(forKey: old) else { return false }
        records[new] = TokenRecord(meta: meta, location: record.location)
        if let c = record.location.cell { cells[c] = new }
        if let g = record.location.group, let i = groups[g]?.firstIndex(of: old) { groups[g]![i] = new }
        return true
    }

    /// Invariant violations (empty when consistent). Used by tests and debug assertions.
    public func violations(grid: ScreenGrid = .standard) -> [String] {
        var out: [String] = []
        var seenCells: [ScreenCell: TokenKey] = [:]
        var seenGroups: [Location.Group: [Int: TokenKey]] = [:]
        for key in sortedKeys {
            let loc = records[key]!.location
            if let c = loc.cell {
                if !grid.contains(c) { out.append("\(key) at \(c) outside the grid") }
                if let other = seenCells[c] { out.append("\(key) and \(other) share \(c)") }
                seenCells[c] = key
                if cells[c] != key { out.append("cell index disagrees for \(key)") }
            }
            if let g = loc.group, let order = loc.order {
                if seenGroups[g, default: [:]][order] != nil { out.append("duplicate order \(order) in \(g)") }
                seenGroups[g, default: [:]][order] = key
                if groups[g]?.firstIndex(of: key) != order { out.append("order index disagrees for \(key)") }
            }
        }
        if cells.count != seenCells.count { out.append("stale cell index entries") }
        for (g, members) in groups {
            let orders = seenGroups[g] ?? [:]
            if members.isEmpty { out.append("empty group \(g) kept") }
            if Set(orders.keys) != Set(0..<members.count) { out.append("orders in \(g) are not 0..<\(members.count)") }
            if case let .container(id) = g, members.count > id.spec.hardCap { out.append("\(id) over its hard cap") }
        }
        if seenGroups.count != groups.count { out.append("group index out of sync") }
        return out
    }

    // MARK: Index maintenance

    private mutating func attach(_ key: TokenKey, _ location: Location) {
        if let c = location.cell {
            cells[c] = key
        } else if let g = location.group, let order = location.order {
            var list = groups[g] ?? []
            let i = min(max(order, 0), list.count)
            list.insert(key, at: i)
            groups[g] = list
            renumber(g, from: i)
        }
    }

    private mutating func detach(_ key: TokenKey, _ location: Location) {
        if let c = location.cell {
            if cells[c] == key { cells[c] = nil }
        } else if let g = location.group, var list = groups[g], let i = list.firstIndex(of: key) {
            list.remove(at: i)
            groups[g] = list.isEmpty ? nil : list
            renumber(g, from: i)
        }
    }

    private mutating func renumber(_ g: Location.Group, from start: Int) {
        guard let list = groups[g] else { return }
        for i in start..<list.count {
            let key = list[i]
            records[key]!.location = records[key]!.location.withOrder(i)
        }
    }
}

// MARK: - Element states (persisted; DESIGN §13)

/// Whether the desktop folder is mirrored (DESIGN §3.1 item 2). Runtime only.
public enum DesktopAccess: String, Sendable, Codable {
    /// First run: the screen asks to press ⏻ to connect.
    case notConnected
    /// Finder hides desktop items; the screen asks whether to show them anyway.
    case finderHidden
    /// The first enumeration is running.
    case connecting
    case connected
    /// The folder could not be read (TCC denied): NO SIGNAL card.
    case denied
}

public enum PowerState: String, Codable, Sendable {
    case on, off
}

public struct MonitorState: Codable, Sendable, Equatable {
    public var power: PowerState = .on
    /// Current HDMI page (0 = HDMI 1).
    public var page: Int = 0
    /// The AV input (always empty) is selected.
    public var av: Bool = false
    /// Files that arrived while the monitor was off (the "+N" badge).
    public var pendingNew: Int = 0

    public init() {}

    private enum CodingKeys: String, CodingKey { case power, page, av, pendingNew }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        power = c.lenient(.power, default: .on)
        page = max(0, c.lenient(.page, default: 0))
        av = c.lenient(.av, default: false)
        pendingNew = max(0, c.lenient(.pendingNew, default: 0))
    }
}

public struct DrawerState: Codable, Sendable, Equatable {
    /// Open distance in art px.
    public var p: Float

    public init(p: Float = 0) { self.p = p }
}

public struct PhoneState: Codable, Sendable, Equatable {
    public var faceDown: Bool = false

    public init(faceDown: Bool = false) { self.faceDown = faceDown }
}

/// Pen cup machine state (M6/M7 type the `state` strings: upright, wobble, tipping, lying…, righting).
public struct PenCupState: Codable, Sendable, Equatable {
    public var state: String = "upright"
    /// Desk-plane position (x, d).
    public var pos: SIMD2<Float> = [367, 120]

    public init(state: String = "upright", pos: SIMD2<Float> = [367, 120]) {
        self.state = state
        self.pos = pos
    }
}

/// Wastebasket machine state (`state`: upright, tipped…; typed in M6/M7).
public struct BasketState: Codable, Sendable, Equatable {
    public var state: String = "upright"
    public var swishes: Int = 0

    public init(state: String = "upright", swishes: Int = 0) {
        self.state = state
        self.swishes = swishes
    }
}

public struct ChairState: Codable, Sendable, Equatable {
    public var x: Float = 200
    public var facing: Int = 0

    public init(x: Float = 200, facing: Int = 0) {
        self.x = x
        self.facing = facing
    }
}

public enum LightsMode: String, Codable, CaseIterable, Sendable {
    case auto, day, night, lampOnly
}

public struct LightsState: Codable, Sendable, Equatable {
    public var mode: LightsMode = .auto
    public var room: Bool = true
    public var lamp: Bool = true

    public init(mode: LightsMode = .auto, room: Bool = true, lamp: Bool = true) {
        self.mode = mode
        self.room = room
        self.lamp = lamp
    }

    private enum CodingKeys: String, CodingKey { case mode, room, lamp }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.lenient(.mode, default: .auto)
        room = c.lenient(.room, default: true)
        lamp = c.lenient(.lamp, default: true)
    }
}

public struct BrushState: Codable, Sendable, Equatable {
    /// Desk-plane position (x, d).
    public var pos: SIMD2<Float> = [442, 60]

    public init(pos: SIMD2<Float> = [442, 60]) { self.pos = pos }
}

/// The desk mat (E9). The cloth (M8/M9) owns `particles` (base64 Float32 LE xyz).
public struct MatState: Codable, Sendable, Equatable {
    public var pattern: String = "felt"
    public var mode: String = "cloth"
    public var origin: SIMD2<Float> = [154, 8]
    public var size: SIMD2<Float> = [204, 84]
    public var angle: Float = 0
    public var grid: [Int] = [35, 15]
    public var particles: String?

    public init() {}

    private enum CodingKeys: String, CodingKey { case pattern, mode, origin, size, angle, grid, particles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MatState()
        pattern = c.lenient(.pattern, default: d.pattern)
        mode = c.lenient(.mode, default: d.mode)
        origin = c.lenient(.origin, default: d.origin)
        size = c.lenient(.size, default: d.size)
        angle = c.lenient(.angle, default: d.angle)
        grid = c.lenient(.grid, default: d.grid)
        particles = c.lenient(.particles, default: nil)
    }
}

public struct DeskFlags: Codable, Sendable, Equatable {
    public var onboardingStep: Int = 0
    public var askedCoverDisplays: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case onboardingStep, askedCoverDisplays }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onboardingStep = c.lenient(.onboardingStep, default: 0)
        askedCoverDisplays = c.lenient(.askedCoverDisplays, default: false)
    }
}

/// The mirrored folder.
public struct DesktopRoot: Codable, Sendable, Equatable {
    public var path: String
    public var volume: String

    public init(path: String, volume: String) {
        self.path = path
        self.volume = volume
    }
}

/// A removed token's last place, kept 7 days so a returning file goes back there (DESIGN §3.2).
public struct Tombstone: Codable, Sendable, Equatable {
    public static let lifetime: TimeInterval = 7 * 24 * 3600
    /// The newest tombstones kept, so a churning desktop cannot grow `desk.json` without bound.
    public static let maxCount = 2000

    public var key: TokenKey
    /// Raw file name.
    public var name: String
    public var kind: FileKind
    public var loc: Location
    public var until: Date
    /// The pile's desk-plane position at removal, so an emptied pile can come back.
    public var pilePos: SIMD2<Float>?

    public init(key: TokenKey, name: String, kind: FileKind, loc: Location, until: Date, pilePos: SIMD2<Float>? = nil) {
        self.key = key
        self.name = name
        self.kind = kind
        self.loc = loc
        self.until = until
        self.pilePos = pilePos
    }

    /// When the file disappeared.
    public var removedAt: Date { until.addingTimeInterval(-Self.lifetime) }
}

// MARK: - DeskState

/// The whole desk: token membership plus every element's committed state (DESIGN §13). Runtime-only fields
/// (`access`, `hints`, `volumes`) are not persisted.
public struct DeskState: Sendable, Equatable {
    public var root: DesktopRoot?
    public var hostDisplayUUID: String?
    public var monitor = MonitorState()
    public var drawers: [ContainerID: DrawerState] = Dictionary(
        uniqueKeysWithValues: ContainerID.allCases.filter(\.isDrawer).map { ($0, DrawerState()) }
    )
    public var phone = PhoneState()
    public var penCup = PenCupState()
    public var wastebasket = BasketState()
    public var chair = ChairState()
    public var lights = LightsState()
    public var brush = BrushState()
    public var mat = MatState()
    /// Desk-plane positions of piles; every pile here holds at least one token.
    public var piles: [PileID: SIMD2<Float>] = [:]
    public var tokens = TokenStore()
    public var tombstones: [Tombstone] = []
    public var flags = DeskFlags()

    public var access: DesktopAccess = .notConnected
    /// Placement hints registered by our own operations (name → location, 10 s TTL).
    public var hints: [PlacementHint] = []
    public var volumes: [VolumeEntry] = []

    public init() {}

    public func drawerOpening(_ id: ContainerID) -> Float { drawers[id]?.p ?? 0 }

    /// Monitor pages in use (HDMI 1…n): trailing empty pages are not counted; page 0 always is.
    public func pageCount(grid: ScreenGrid = .standard) -> Int { grid.pageCount(tokens.occupiedCells) }

    /// The URL of a token's file, when the root is known.
    public func url(of key: TokenKey) -> URL? {
        guard let root, let meta = tokens.meta(of: key) else { return nil }
        return URL(fileURLWithPath: root.path, isDirectory: true)
            .appendingPathComponent(meta.name, isDirectory: meta.kind == .folder)
    }

    /// A pile id not in use (`P1`, `P2`, …).
    public func makePileID() -> PileID {
        var n = 1
        let used = Set(piles.keys).union(tokens.piles)
        while used.contains(PileID("P\(n)")) { n += 1 }
        return PileID("P\(n)")
    }

    /// Model invariant violations (empty when consistent).
    public func violations(grid: ScreenGrid = .standard) -> [String] {
        var out = tokens.violations(grid: grid)
        let used = Set(tokens.piles)
        for p in used where piles[p] == nil { out.append("pile \(p) has no position") }
        for p in piles.keys where !used.contains(p) { out.append("pile \(p) is empty") }
        for t in tombstones where tokens.contains(t.key) { out.append("tombstone for live token \(t.key)") }
        if monitor.page < 0 || monitor.page >= pageCount(grid: grid) { out.append("monitor page \(monitor.page) out of range") }
        return out
    }
}

// MARK: - Lenient decoding

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it is missing or malformed (persisted state degrades per field).
    func lenient<T: Decodable>(_ key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
