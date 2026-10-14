import Foundation

/// `desk.json`, schema 1 (DESIGN §13): the persisted layout. Coordinates are element-relative; covered-ness,
/// carries, selection, velocities and file contents are never stored. Decoding is lenient per field and per
/// token, so one bad value degrades to its default instead of losing the layout.
public struct DeskDocument: Codable, Sendable, Equatable {
    public struct TokenEntry: Codable, Sendable, Equatable {
        public var key: TokenKey
        public var meta: TokenMeta
        public var loc: Location

        public init(key: TokenKey, meta: TokenMeta, loc: Location) {
            self.key = key
            self.meta = meta
            self.loc = loc
        }
    }

    public struct PileEntry: Codable, Sendable, Equatable {
        public var id: PileID
        public var pos: SIMD2<Float>

        public init(id: PileID, pos: SIMD2<Float>) {
            self.id = id
            self.pos = pos
        }
    }

    public var schema: Int = Migrations.currentSchema
    public var layoutVersion: Int = Migrations.currentLayoutVersion
    public var app: String = DeskCore.version
    public var savedAt: Date?
    public var root: DesktopRoot?
    public var hostDisplayUUID: String?
    public var monitor = MonitorState()
    /// Keyed by `ContainerID` raw value (drawers only).
    public var drawers: [String: DrawerState] = [:]
    public var phone = PhoneState()
    public var penCup = PenCupState()
    public var wastebasket = BasketState()
    public var chair = ChairState()
    public var lights = LightsState()
    public var brush = BrushState()
    public var mat = MatState()
    public var piles: [PileEntry] = []
    /// Sorted by key.
    public var tokens: [TokenEntry] = []
    public var tombstones: [Tombstone] = []
    public var flags = DeskFlags()

    public init() {}

    /// The persisted form of `state`. A carried token (a carry interrupted by a quit) is written at its origin
    /// (or the first free monitor cell when it has none). Non-finite numbers, which JSON cannot hold, fall back
    /// to defaults, so encoding never fails.
    public init(state: DeskState, savedAt: Date, app: String = DeskCore.version, grid: ScreenGrid = .standard) {
        self.savedAt = savedAt
        self.app = app
        root = state.root
        hostDisplayUUID = state.hostDisplayUUID
        monitor = state.monitor
        drawers = Dictionary(uniqueKeysWithValues: state.drawers.map {
            ($0.key.rawValue, $0.value.p.isFinite ? $0.value : DrawerState())
        })
        phone = state.phone
        penCup = state.penCup
        if !penCup.pos.isFinite { penCup.pos = PenCupState().pos }
        wastebasket = state.wastebasket
        chair = state.chair
        if !chair.x.isFinite { chair.x = ChairState().x }
        lights = state.lights
        brush = state.brush.pos.isFinite ? state.brush : BrushState()
        mat = state.mat
        if !mat.isFinite {
            let d = MatState()
            (mat.origin, mat.size, mat.angle) = (d.origin, d.size, d.angle)
        }
        piles = state.piles.keys.sorted().map {
            PileEntry(id: $0, pos: state.piles[$0]!.isFinite ? state.piles[$0]! : Placement.defaultPilePos)
        }
        var allocator = ScreenGrid.Allocator(grid: grid, occupied: state.tokens.occupiedCells)
        tokens = state.tokens.sortedKeys.map { key in
            let r = state.tokens[key]!
            var loc = state.tokens.restingLocation(of: key)!
            if loc == .carried { loc = allocator.next().location }
            return TokenEntry(key: key, meta: r.meta, loc: loc)
        }
        tombstones = state.tombstones.sorted { ($0.until, $0.key) < ($1.until, $1.key) }.map {
            var t = $0
            if t.pilePos?.isFinite == false { t.pilePos = nil }
            return t
        }
        flags = state.flags
    }

    /// Rebuilds the model. Tokens are re-inserted in container/pile order (closing gaps); tokens whose saved
    /// spot is invalid (shared cell, outside the grid, over a hard cap, carried) go to the first free cells.
    public func makeState(grid: ScreenGrid = .standard) -> DeskState {
        var s = DeskState()
        s.root = root
        s.access = root == nil ? .notConnected : .connected
        s.hostDisplayUUID = hostDisplayUUID
        s.monitor = monitor
        for (raw, drawer) in drawers {
            if let id = ContainerID(rawValue: raw), id.isDrawer { s.drawers[id] = drawer }
        }
        s.phone = phone
        s.penCup = penCup
        s.wastebasket = wastebasket
        s.chair = chair
        s.lights = lights
        s.brush = brush
        s.mat = mat
        s.flags = flags
        for p in piles { s.piles[p.id] = p.pos }

        let ordered = tokens.sorted { a, b in
            (a.loc.order ?? 0, a.key) < (b.loc.order ?? 0, b.key)
        }
        var misplaced: [TokenEntry] = []
        for t in ordered where !s.tokens.contains(t.key) {
            if case let .desk(pile, _) = t.loc, s.piles[pile] == nil { s.piles[pile] = Placement.defaultPilePos }
            let ok = t.loc != .carried && s.tokens.insert(t.key, meta: t.meta, at: t.loc, grid: grid)
            if !ok { misplaced.append(t) }
        }
        var allocator = ScreenGrid.Allocator(grid: grid, occupied: s.tokens.occupiedCells)
        for t in misplaced where !s.tokens.contains(t.key) {
            s.tokens.insert(t.key, meta: t.meta, at: allocator.next().location, grid: grid)
        }
        Placement.pruneEmptyPiles(&s)
        s.tombstones = tombstones.filter { !s.tokens.contains($0.key) }
        s.monitor.page = min(max(0, s.monitor.page), s.pageCount(grid: grid) - 1)
        return s
    }

    // MARK: JSON

    /// Decodes `data` after running schema migrations; then layout migrations; then brings values no desk could have
    /// saved back into range (`sanitized`, Errata 25).
    public static func decode(_ data: Data) throws -> DeskDocument {
        var doc = try makeDecoder().decode(DeskDocument.self, from: try Migrations.migrate(data))
        Migrations.migrateLayout(&doc)
        return doc.sanitized()
    }

    /// Pretty, key-sorted JSON (stable diffs).
    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISODate.format(date))
        }
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISODate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(s)")
            }
            return date
        }
        return d
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case schema, layoutVersion, app, savedAt, root, hostDisplayUUID, monitor, drawers, phone, penCup,
             wastebasket, chair, lights, brush, mat, piles, tokens, tombstones, undo, flags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeskDocument()
        schema = try c.decode(Int.self, forKey: .schema)
        layoutVersion = c.lenient(.layoutVersion, default: d.layoutVersion)
        app = c.lenient(.app, default: "")
        savedAt = c.lenient(.savedAt, default: nil)
        root = c.lenient(.root, default: nil)
        hostDisplayUUID = c.lenient(.hostDisplayUUID, default: nil)
        monitor = c.lenient(.monitor, default: d.monitor)
        drawers = c.lenient(.drawers, default: d.drawers)
        phone = c.lenient(.phone, default: d.phone)
        penCup = c.lenient(.penCup, default: d.penCup)
        wastebasket = c.lenient(.wastebasket, default: d.wastebasket)
        chair = c.lenient(.chair, default: d.chair)
        lights = c.lenient(.lights, default: d.lights)
        brush = c.lenient(.brush, default: d.brush)
        mat = c.lenient(.mat, default: d.mat)
        piles = c.lenient(.piles, default: Lossy<PileEntry>()).elements
        // A token list that is not an array at all, or of which no token can be read, means the file is damaged:
        // fail and use a backup.
        let list = try c.decodeIfPresent(Lossy<TokenEntry>.self, forKey: .tokens)
        if let list, list.elements.isEmpty, list.skipped > 0 {
            throw DecodingError.dataCorruptedError(forKey: .tokens, in: c, debugDescription: "no token could be read")
        }
        tokens = list?.elements ?? []
        tombstones = c.lenient(.tombstones, default: Lossy<Tombstone>()).elements
        flags = c.lenient(.flags, default: d.flags)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(layoutVersion, forKey: .layoutVersion)
        try c.encode(app, forKey: .app)
        try c.encodeIfPresent(savedAt, forKey: .savedAt)
        try c.encodeIfPresent(root, forKey: .root)
        try c.encodeIfPresent(hostDisplayUUID, forKey: .hostDisplayUUID)
        try c.encode(monitor, forKey: .monitor)
        try c.encode(drawers, forKey: .drawers)
        try c.encode(phone, forKey: .phone)
        try c.encode(penCup, forKey: .penCup)
        try c.encode(wastebasket, forKey: .wastebasket)
        try c.encode(chair, forKey: .chair)
        try c.encode(lights, forKey: .lights)
        try c.encode(brush, forKey: .brush)
        try c.encode(mat, forKey: .mat)
        try c.encode(piles, forKey: .piles)
        try c.encode(tokens, forKey: .tokens)
        try c.encode(tombstones, forKey: .tombstones)
        // TODO(M5): UndoJournal entries.
        try c.encode([String](), forKey: .undo)
        try c.encode(flags, forKey: .flags)
    }
}

extension DeskState: Codable {
    /// Through `DeskDocument`; runtime-only fields reset.
    public init(from decoder: Decoder) throws {
        self = try DeskDocument(from: decoder).makeState()
    }

    public func encode(to encoder: Encoder) throws {
        try DeskDocument(state: self, savedAt: Date(timeIntervalSince1970: 0)).encode(to: encoder)
    }
}

/// Decodes an array element by element, skipping elements that do not decode.
struct Lossy<Element: Decodable>: Decodable {
    var elements: [Element] = []
    /// Elements that did not decode.
    var skipped = 0

    init() {}

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if let e = try? c.decode(Element.self) {
                elements.append(e)
            } else {
                _ = try c.decode(Skip.self)
                skipped += 1
            }
        }
    }

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// ISO 8601 dates in UTC with optional milliseconds. Formatting and parsing are exact to the millisecond
/// (`wholeMilliseconds(d)` survives a round trip unchanged); the system format style alone truncates.
enum ISODate {
    private static let whole = Date.ISO8601FormatStyle()

    /// `date` rounded to whole milliseconds.
    static func wholeMilliseconds(_ date: Date) -> Date {
        let t = date.timeIntervalSince1970
        guard t.isFinite, abs(t) < 1e15 else { return date }
        return Date(timeIntervalSince1970: Double(Int64((t * 1000).rounded())) / 1000)
    }

    static func format(_ date: Date) -> String {
        let t = date.timeIntervalSince1970
        guard t.isFinite, abs(t) < 1e15 else { return whole.format(date) }
        let total = Int64((t * 1000).rounded())
        let seconds = total >= 0 ? total / 1000 : -((-total + 999) / 1000)
        let ms = Int(total - seconds * 1000)
        let base = whole.format(Date(timeIntervalSince1970: Double(seconds)))
        guard ms != 0, base.hasSuffix("Z") else { return base }
        return String(base.dropLast()) + "." + String(format: "%03d", ms) + "Z"
    }

    static func parse(_ s: String) -> Date? {
        guard let dot = s.firstIndex(of: ".") else { return try? whole.parse(s) }
        guard s.hasSuffix("Z") else { return nil }
        let digits = s[s.index(after: dot)..<s.index(before: s.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let base = try? whole.parse(String(s[..<dot]) + "Z")
        else { return nil }
        let ms = Int64(String((digits + "00").prefix(3)))!
        let seconds = Int64(base.timeIntervalSince1970.rounded())
        return Date(timeIntervalSince1970: Double(seconds * 1000 + ms) / 1000)
    }
}
