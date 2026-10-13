/// Every hiding place that holds tokens in an ordered list (DESIGN §2.2).
public enum ContainerID: String, Codable, CaseIterable, Sendable, Comparable {
    case riserLeft, riserRight, riserCubby, cabinetTop, cabinetMiddle, cabinetFile, penCup, phone, wastebasket

    public static func < (a: ContainerID, b: ContainerID) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Capacity, hard cap and concealment.
    public var spec: ContainerSpec { ContainerSpec.of(self) }

    /// Drawers that slide on a rail (riser and cabinet).
    public var isDrawer: Bool {
        switch self {
        case .riserLeft, .riserRight, .cabinetTop, .cabinetMiddle, .cabinetFile: true
        default: false
        }
    }
}

/// A loose desk pile; its desk-plane position lives in `DeskState.piles`.
public struct PileID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var raw: String

    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { self.raw = value }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    public static func < (a: PileID, b: PileID) -> Bool {
        a.raw.count != b.raw.count ? a.raw.count < b.raw.count : a.raw < b.raw
    }

    public var description: String { raw }
}

/// A monitor cell: page (HDMI page − 1), column 0…8, row 0…4.
public struct ScreenCell: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var page: Int
    public var col: Int
    public var row: Int

    public init(page: Int, col: Int, row: Int) {
        self.page = page
        self.col = col
        self.row = row
    }

    /// Reading order: page, then row, then column.
    public static func < (a: ScreenCell, b: ScreenCell) -> Bool {
        (a.page, a.row, a.col) < (b.page, b.row, b.col)
    }

    public var location: Location { .screen(page: page, col: col, row: row) }
    public var description: String { "p\(page)(\(col),\(row))" }
}

/// Where a token lives. Every live token has exactly one (DESIGN §4.2). JSON form follows §13:
/// `{"screen":{"page":0,"col":2,"row":1}}`, `{"container":{"id":"cabinetMiddle","order":3}}`,
/// `{"desk":{"pile":"P1","order":0}}`, `{"floor":{"x":210}}`.
public enum Location: Hashable, Sendable, Codable, CustomStringConvertible {
    case screen(page: Int, col: Int, row: Int)
    case container(ContainerID, order: Int)
    /// Covered-ness is derived from the cloth, never stored.
    case desk(pile: PileID, order: Int)
    /// Core x on the floor line.
    case floor(x: Int)
    /// Transient while a token is being carried; never persisted.
    case carried

    public var cell: ScreenCell? {
        if case let .screen(page, col, row) = self { return ScreenCell(page: page, col: col, row: row) }
        return nil
    }

    public var container: ContainerID? {
        if case let .container(id, _) = self { return id }
        return nil
    }

    public var pile: PileID? {
        if case let .desk(pile, _) = self { return pile }
        return nil
    }

    public var isScreen: Bool { cell != nil }

    /// The ordered list this location is part of (container or pile), if any.
    var group: Group? {
        switch self {
        case let .container(id, _): .container(id)
        case let .desk(pile, _): .pile(pile)
        default: nil
        }
    }

    /// The position inside `group`.
    var order: Int? {
        switch self {
        case let .container(_, order), let .desk(_, order): order
        default: nil
        }
    }

    /// The same location with a different order (only for container and pile locations).
    func withOrder(_ order: Int) -> Location {
        switch self {
        case let .container(id, _): .container(id, order: order)
        case let .desk(pile, _): .desk(pile: pile, order: order)
        default: self
        }
    }

    enum Group: Hashable {
        case container(ContainerID)
        case pile(PileID)
    }

    public var description: String {
        switch self {
        case let .screen(page, col, row): "screen p\(page)(\(col),\(row))"
        case let .container(id, order): "\(id.rawValue)#\(order)"
        case let .desk(pile, order): "desk \(pile)#\(order)"
        case let .floor(x): "floor x\(x)"
        case .carried: "carried"
        }
    }

    // MARK: Codable

    private enum Key: String, CodingKey {
        case screen, container, desk, floor, carried
    }

    private enum Field: String, CodingKey {
        case page, col, row, id, order, pile, x
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard let key = c.allKeys.first, c.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "a location has exactly one key")
            )
        }
        if key == .carried {
            self = .carried
            return
        }
        let f = try c.nestedContainer(keyedBy: Field.self, forKey: key)
        switch key {
        case .screen:
            self = .screen(
                page: try f.decode(Int.self, forKey: .page), col: try f.decode(Int.self, forKey: .col),
                row: try f.decode(Int.self, forKey: .row)
            )
        case .container:
            self = .container(try f.decode(ContainerID.self, forKey: .id), order: try f.decode(Int.self, forKey: .order))
        case .desk:
            self = .desk(pile: try f.decode(PileID.self, forKey: .pile), order: try f.decode(Int.self, forKey: .order))
        case .floor:
            self = .floor(x: try f.decode(Int.self, forKey: .x))
        case .carried:
            self = .carried
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .screen(page, col, row):
            var f = c.nestedContainer(keyedBy: Field.self, forKey: .screen)
            try f.encode(page, forKey: .page)
            try f.encode(col, forKey: .col)
            try f.encode(row, forKey: .row)
        case let .container(id, order):
            var f = c.nestedContainer(keyedBy: Field.self, forKey: .container)
            try f.encode(id, forKey: .id)
            try f.encode(order, forKey: .order)
        case let .desk(pile, order):
            var f = c.nestedContainer(keyedBy: Field.self, forKey: .desk)
            try f.encode(pile, forKey: .pile)
            try f.encode(order, forKey: .order)
        case let .floor(x):
            var f = c.nestedContainer(keyedBy: Field.self, forKey: .floor)
            try f.encode(x, forKey: .x)
        case .carried:
            _ = c.nestedContainer(keyedBy: Field.self, forKey: .carried)
        }
    }
}
