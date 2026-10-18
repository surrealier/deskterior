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
    /// Where each carried token was picked up (DESIGN §13: an interrupted carry commits to its origin).
    private var origins: [TokenKey: Location] = [:]

    public init() {}

    public var count: Int { records.count }
    public var isEmpty: Bool { records.isEmpty }
    /// Keys in ascending order (deterministic iteration).
    public var sortedKeys: [TokenKey] { records.keys.sorted() }

    public subscript(key: TokenKey) -> TokenRecord? { records[key] }
    public func contains(_ key: TokenKey) -> Bool { records[key] != nil }
    public func location(of key: TokenKey) -> Location? { records[key]?.location }
    public func meta(of key: TokenKey) -> TokenMeta? { records[key]?.meta }
    /// Where a carried token was picked up (nil when it is not carried or was inserted carried).
    public func origin(of key: TokenKey) -> Location? { origins[key] }
    /// The token's place for persistence and tombstones: its origin while it is carried.
    public func restingLocation(of key: TokenKey) -> Location? {
        guard let loc = records[key]?.location else { return nil }
        return loc == .carried ? origins[key] ?? .carried : loc
    }
    /// Piles that carried tokens were picked up from (kept so an interrupted carry can return there).
    public var originPiles: Set<PileID> { Set(origins.values.compactMap(\.pile)) }

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
        origins[key] = nil
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
        if location == .carried {
            if record.location != .carried { origins[key] = record.location }
        } else {
            origins[key] = nil
        }
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
        if let origin = origins.removeValue(forKey: old) { origins[new] = origin }
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
        for key in origins.keys where records[key]?.location != .carried { out.append("origin kept for uncarried \(key)") }
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

/// The persisted desk mat (E9, `desk.json` → `"mat"`, DESIGN §13). The cloth (DeskCore/Cloth) writes it with
/// `ClothSim.matState()` and reads it back with `ClothSim.restore(state:piles:)`.
public struct MatState: Codable, Sendable, Hashable {
    public var pattern: String = "felt"
    public var mode: String = "cloth"
    /// Desk-plane `[x, d]` of the mat's uv (0, 0) corner (best-fit frame).
    public var origin: SIMD2<Float> = [154, 8]
    /// Rest `[width, depth]`.
    public var size: SIMD2<Float> = [204, 84]
    /// Radians, counter-clockwise in the x/d plane.
    public var angle: Float = 0
    /// `[cols, rows]`.
    public var grid: [Int] = [35, 15]
    /// Every particle as base64 Float32 little-endian `x, d, z` triples (`MatState.encodeParticles`); nil until the
    /// cloth has settled once, in which case the scene lays a fresh flat mat from the frame above.
    public var particles: String?
    /// Desk-plane `[x, d]` centre of the keyboard weighing the mat (it rides along with carries), if any.
    public var keyboard: SIMD2<Float>?

    public init() {}

    public init(pattern: String = "felt", mode: String = "cloth", origin: SIMD2<Float>, size: SIMD2<Float>,
                angle: Float, grid: [Int], particles: String?, keyboard: SIMD2<Float>? = nil) {
        self.pattern = pattern
        self.mode = mode
        self.origin = origin
        self.size = size
        self.angle = angle
        self.grid = grid
        self.particles = particles
        self.keyboard = keyboard
    }

    private enum CodingKeys: String, CodingKey { case pattern, mode, origin, size, angle, grid, particles, keyboard }

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
        keyboard = c.lenient(.keyboard, default: nil)
    }
}

extension MatState {
    /// Every coordinate is a finite number (JSON cannot store NaN or infinity).
    public var isFinite: Bool { origin.isFinite && size.isFinite && angle.isFinite }
}

extension SIMD2<Float> {
    public var isFinite: Bool { x.isFinite && y.isFinite }
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
///
/// A file that returns under its old key is the same file. One that returns under a new key matches by NFC name
/// and kind only when that is safe: within `Placement.safeSaveWindow` of a known removal time (a safe-save), or
/// when its size and creation date agree (a copy brought back). Name matches never restore into the wastebasket.
public struct Tombstone: Codable, Sendable, Equatable {
    public static let lifetime: TimeInterval = 7 * 24 * 3600
    /// The tombstones kept, so a churning desktop cannot grow `desk.json` without bound. Screen places are
    /// dropped before hidden ones, then the oldest.
    public static let maxCount = 2000

    public var key: TokenKey
    /// Raw file name.
    public var name: String
    public var kind: FileKind
    public var loc: Location
    public var until: Date
    /// The pile's desk-plane position at removal, so an emptied pile can come back.
    public var pilePos: SIMD2<Float>?
    /// When the file vanished, to within one watcher batch; nil when it was found missing by a launch or
    /// recovery scan (unknown, so never "recent").
    public var removedAt: Date?
    public var size: Int64?
    public var created: Date?

    public init(
        key: TokenKey, name: String, kind: FileKind, loc: Location, until: Date, pilePos: SIMD2<Float>? = nil,
        removedAt: Date? = nil, size: Int64? = nil, created: Date? = nil
    ) {
        self.key = key
        self.name = name
        self.kind = kind
        self.loc = loc
        self.until = until
        self.pilePos = pilePos
        self.removedAt = removedAt
        self.size = size
        self.created = created
    }
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
    // MARK: tidy (0.3.0)
    /// Objects put away (Erratum 30; `StowCatalog`). Element state: kept when another folder's layout is adopted.
    public var stowed: Set<StowID> = []
    /// The partition's clip light is switched on (Erratum 31; not journaled, like the lamp).
    public var clipLightOn = false
    // MARK: memos (0.3.0)
    /// Sticky notes, day pages and the D-Day: saved to `memos.json`, not `desk.json` (Erratum 31).
    public var memos = MemoBook()

    public var access: DesktopAccess = .notConnected
    /// Placement hints registered by our own operations (name → location, 10 s TTL).
    public var hints: [PlacementHint] = []
    public var volumes: [VolumeEntry] = []
    /// Short-lived identity memory of the reconciler (recent renames, backup swaps, re-key aliases).
    public var memory = MirrorMemory()

    public init() {}

    public func drawerOpening(_ id: ContainerID) -> Float { drawers[id]?.p ?? 0 }

    /// Monitor pages in use (HDMI 1…n): trailing empty pages are not counted; page 0 always is.
    public func pageCount(grid: ScreenGrid = .standard) -> Int { grid.pageCount(tokens.occupiedCells) }

    /// The URL of a token's file while the mirror is current (connected), so a stale layout never resolves a
    /// name to some other file. Names that are not a single path component are refused.
    public func url(of key: TokenKey) -> URL? {
        guard access == .connected, let root, let meta = tokens.meta(of: key), Self.isPlainName(meta.name) else {
            return nil
        }
        return URL(fileURLWithPath: root.path, isDirectory: true)
            .appendingPathComponent(meta.name, isDirectory: meta.kind == .folder)
    }

    /// A single, non-empty path component. "/" and NUL are checked by scalar: a "/" carrying a combining mark hides
    /// inside one Character.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.unicodeScalars.contains { $0 == "/" || $0 == "\0" }
    }

    /// The live key for `key`, following recent re-keys (a gesture that started before a safe-save).
    public func currentKey(for key: TokenKey) -> TokenKey {
        tokens.contains(key) ? key : memory.current(key)
    }

    /// A pile id never used by a live pile, a token or a tombstone (`P<n>` past the highest in use), so a
    /// returning file cannot join an unrelated new pile.
    public func makePileID() -> PileID {
        var used = Set(piles.keys).union(tokens.piles).union(tokens.originPiles)
        for t in tombstones { if let p = t.loc.pile { used.insert(p) } }
        let highest = used.compactMap { $0.raw.hasPrefix("P") ? Int($0.raw.dropFirst()) : nil }.max() ?? 0
        return PileID("P\(highest + 1)")
    }

    /// Takes `other`'s token layout (root, tokens, piles, tombstones, monitor page) and keeps this desk's element
    /// states, so switching back to a folder mirrored before restores where its files were. What is put away, the
    /// clip light and the memos are element state and stay; an object whose hiding places hold tokens in the adopted
    /// layout comes back (Erratum 30), and what the adopted layout left where an out object stands (the folder's
    /// layout was saved while it was away) moves aside, as Bring Back does.
    public mutating func adoptLayout(of other: DeskState, grid: ScreenGrid = .standard) {
        root = other.root
        tokens = other.tokens
        piles = other.piles
        tombstones = other.tombstones
        memory = MirrorMemory()
        monitor.page = min(max(0, other.monitor.page), pageCount(grid: grid) - 1)
        bringBackOccupied()
        let standing = StowID.allCases.filter {
            isOut($0) && (StowCatalog.spec($0).footprint != nil || StowCatalog.spec($0).floorSpan != nil)
        }
        _ = Reducer.makeRoom(for: standing, in: &self)
    }

    /// Model invariant violations (empty when consistent).
    public func violations(grid: ScreenGrid = .standard) -> [String] {
        var out = tokens.violations(grid: grid)
        let used = Set(tokens.piles)
        for p in used where piles[p] == nil { out.append("pile \(p) has no position") }
        let origins = tokens.originPiles
        for p in piles.keys where !used.contains(p) && !origins.contains(p) { out.append("pile \(p) is empty") }
        for t in tombstones where tokens.contains(t.key) { out.append("tombstone for live token \(t.key)") }
        if monitor.page < 0 || monitor.page >= pageCount(grid: grid) { out.append("monitor page \(monitor.page) out of range") }
        // MARK: tidy (0.3.0)
        for c in ContainerID.allCases where isAway(c) && tokens.count(in: c) > 0 {
            out.append("away container \(c) holds \(tokens.count(in: c)) tokens")
        }
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
