import Foundation

/// A calendar day, "YYYY-MM-DD" (Erratum 31): the key of a day page, a note's date and the D-Day. Always a real
/// Gregorian date between 1900 and 2999; JSON is the string form. The reducer never reads a calendar: day keys
/// arrive in actions (`DeskScene.today`, the Memos window).
public struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int, month: Int, day: Int

    /// The years a day key may name.
    public static let years: ClosedRange<Int> = 1900...2999

    /// Nil unless `year`, `month` and `day` name a real date in `years`.
    public init?(year: Int, month: Int, day: Int) {
        guard Self.years.contains(year), (1...12).contains(month), (1...Self.daysIn(year, month)).contains(day) else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day of a wall reading (a day past the end of its month, or a year out of range, is clamped).
    public init(_ t: WallTime) {
        year = min(max(t.year, Self.years.lowerBound), Self.years.upperBound)
        month = min(max(t.month, 1), 12)
        day = min(max(t.day, 1), Self.daysIn(year, month))
    }

    /// Parses "YYYY-MM-DD" exactly (four, two and two digits); nil when malformed or not a real date.
    public init?(_ s: String) {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String {
        func pad(_ n: Int, _ width: Int) -> String {
            let s = String(n)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }

    /// Midnight of the day.
    public var wallTime: WallTime { WallTime(year: year, month: month, day: day, hour: 0, minute: 0) }

    /// Day of the week, 0 = Sunday.
    public var weekday: Int { (julianDay + 1) % 7 }

    /// The day `days` later (earlier when negative), clamped to `years`.
    public func adding(days: Int) -> DayKey {
        let lo = DayKey(year: Self.years.lowerBound, month: 1, day: 1)!.julianDay
        let hi = DayKey(year: Self.years.upperBound, month: 12, day: 31)!.julianDay
        return DayKey(julianDay: min(max(julianDay + days, lo), hi))
    }

    /// Days from this day to `other` (negative when `other` is earlier).
    public func days(until other: DayKey) -> Int { other.julianDay - julianDay }

    public static func < (a: DayKey, b: DayKey) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    // MARK: Julian days

    /// The Julian day number (Fliegel and Van Flandern; Gregorian calendar).
    var julianDay: Int {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        return day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    private init(julianDay j: Int) {
        let a = j + 32044
        let b = (4 * a + 3) / 146_097
        let c = a - 146_097 * b / 4
        let d = (4 * c + 3) / 1461
        let e = c - 1461 * d / 4
        let m = (5 * e + 2) / 153
        day = e - (153 * m + 2) / 5 + 1
        month = m + 3 - 12 * (m / 10)
        year = 100 * b + d - 4800 + m / 10
    }

    private static func daysIn(_ year: Int, _ month: Int) -> Int {
        WallTime(year: year, month: month, day: 1, hour: 0, minute: 0).daysInMonth
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let key = DayKey(s) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not a day: \(s)")
            )
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// A sticky note's id, "N<n>" (n ≥ 1). Ids are never reused (`MemoBook.nextNote`); even ids wear tape, odd ones a
/// pushpin.
public struct NoteID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(_ n: Int) { raw = "N\(n)" }

    /// Nil unless `raw` is "N" and a positive number written without leading zeros.
    public init?(raw: String) {
        let digits = raw.dropFirst()
        guard raw.first == "N", !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(digits), n > 0, String(n) == digits
        else { return nil }
        self.raw = raw
    }

    public var number: Int { Int(raw.dropFirst()) ?? 0 }

    public var description: String { raw }

    public static func < (a: NoteID, b: NoteID) -> Bool {
        a.number != b.number ? a.number < b.number : a.raw < b.raw
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let id = NoteID(raw: s) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not a note id: \(s)")
            )
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

/// The six sticky-note colours (each an Apollo ramp: step 5 face, 4 edge, 3 curl). An unknown colour reads as
/// yellow.
public enum NoteColour: String, Codable, CaseIterable, Sendable {
    case yellow, pink, sky, lime, orange, cream

    /// The menu name (English; translated through `L10n.tr`).
    public var title: String {
        switch self {
        case .yellow: "Yellow"
        case .pink: "Pink"
        case .sky: "Sky"
        case .lime: "Lime"
        case .orange: "Orange"
        case .cream: "Cream"
        }
    }

    public init(from decoder: Decoder) throws {
        self = NoteColour(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .yellow
    }
}

/// One sticky note on the partition (Erratum 31). Not a file: notes live in `memos.json`.
public struct StickyNote: Codable, Sendable, Equatable {
    public var id: NoteID
    public var text: String
    public var colour: NoteColour
    /// Core px, the note's top-left; JSON `[x, y]`.
    public var pos: ArtPoint
    /// Stacking order, back to front.
    public var z: Int
    /// The day it is dated (a red corner flag; the calendar marks it).
    public var day: DayKey?
    public var created: Date
    public var edited: Date

    public init(id: NoteID, text: String, colour: NoteColour, pos: ArtPoint, z: Int, day: DayKey? = nil,
                created: Date, edited: Date) {
        self.id = id
        self.text = text
        self.colour = colour
        self.pos = pos
        self.z = z
        self.day = day
        self.created = created
        self.edited = edited
    }

    private enum CodingKeys: String, CodingKey { case id, text, colour, pos, z, day, created, edited }

    /// The id and position are needed; every other field degrades on its own.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(NoteID.self, forKey: .id)
        let xy = try c.decode([Int].self, forKey: .pos)
        guard xy.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .pos, in: c, debugDescription: "a position is [x, y]")
        }
        pos = ArtPoint(xy[0], xy[1])
        text = c.lenient(.text, default: "")
        colour = c.lenient(.colour, default: .yellow)
        z = c.lenient(.z, default: 0)
        day = c.lenient(.day, default: nil)
        created = c.lenient(.created, default: Date(timeIntervalSince1970: 0))
        edited = c.lenient(.edited, default: created)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(colour, forKey: .colour)
        try c.encode([pos.x, pos.y], forKey: .pos)
        try c.encode(z, forKey: .z)
        try c.encodeIfPresent(day, forKey: .day)
        try c.encode(created, forKey: .created)
        try c.encode(edited, forKey: .edited)
    }
}

/// The D-Day the card counts down to.
public struct DDay: Codable, Sendable, Equatable {
    public var day: DayKey
    public var title: String

    public init(day: DayKey, title: String) {
        self.day = day
        self.title = title
    }
}

/// What the wall calendar marks on a day: a day page, a dated note, the D-Day.
public struct CalendarMark: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let memo = CalendarMark(rawValue: 1)
    public static let note = CalendarMark(rawValue: 2)
    public static let dDay = CalendarMark(rawValue: 4)
}

/// Every sticky note, day page and the D-Day (`DeskState.memos`, saved to `memos.json`, Erratum 31).
public struct MemoBook: Sendable, Equatable {
    public static let maxNotes = 24, maxText = 1000, maxTitle = 24
    /// The most UTF-8 one text keeps: a grapheme can be any length (a letter under thousands of combining marks), so
    /// `maxText` alone does not bound the file. Ample for 1000 graphemes of any script or emoji, and it keeps a memo
    /// under Save as Text File's 64 KB.
    public static let maxTextBytes = 32 << 10

    public var notes: [NoteID: StickyNote] = [:]
    /// Day pages; only non-empty ones are kept.
    public var pages: [DayKey: String] = [:]
    public var dDay: DDay?
    /// The number of the next new note; ids are never reused.
    public var nextNote = 1

    public init() {}

    /// The id a new note takes.
    public var nextNoteID: NoteID {
        NoteID(max(nextNote, (notes.keys.map(\.number).max() ?? 0) + 1))
    }

    /// Notes back to front: by z, then id.
    public var backToFront: [StickyNote] {
        notes.values.sorted { ($0.z, $0.id) < ($1.z, $1.id) }
    }

    /// The notes dated `day`, back to front.
    public func notes(on day: DayKey) -> [StickyNote] {
        backToFront.filter { $0.day == day }
    }

    /// The calendar's marks for a month, by day of the month: a page, a dated note, the D-Day.
    public func marks(year: Int, month: Int) -> [Int: CalendarMark] {
        var out: [Int: CalendarMark] = [:]
        func mark(_ d: DayKey, _ m: CalendarMark) {
            if d.year == year && d.month == month { out[d.day, default: []].insert(m) }
        }
        for (d, text) in pages where !text.isEmpty { mark(d, .memo) }
        for n in notes.values { if let d = n.day { mark(d, .note) } }
        if let d = dDay { mark(d.day, .dDay) }
        return out
    }

    /// Text as the book keeps it: NFC; CRLF and CR as LF; Unicode control characters (Cc) removed except newline
    /// and tab; at most `limit` graphemes and `maxTextBytes` of UTF-8 (cut between graphemes).
    public static func clean(_ text: String, limit: Int = maxText) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for u in lines.unicodeScalars where u == "\n" || u == "\t" || u.properties.generalCategory != .control {
            scalars.append(u)
        }
        let kept = TextLayout.nfc(String(scalars)).prefix(max(0, limit))
        guard kept.utf8.count > maxTextBytes else { return String(kept) }
        var end = kept.startIndex, bytes = 0
        while end < kept.endIndex {
            let next = kept.index(after: end)
            bytes += kept[end..<next].utf8.count
            if bytes > maxTextBytes { break }
            end = next
        }
        return String(kept[..<end])
    }
}

/// A note to add (`DeskAction.addNote`): its id (`MemoBook.nextNoteID`) and where it was dropped (nil: the first
/// free default spot).
public struct NewNote: Sendable, Equatable {
    public var id: NoteID
    public var text: String
    public var colour: NoteColour
    public var day: DayKey?
    public var at: ArtPoint?

    public init(id: NoteID, text: String, colour: NoteColour, day: DayKey? = nil, at: ArtPoint? = nil) {
        self.id = id
        self.text = text
        self.colour = colour
        self.day = day
        self.at = at
    }
}

/// A memo that can be saved as a text file: a note or a day page.
public enum MemoRef: Sendable, Hashable {
    case note(NoteID)
    case day(DayKey)
}

/// What the Memos window opens on.
public enum MemoTarget: Sendable, Equatable {
    case today
    case day(DayKey)
    case note(NoteID)
    /// The Sticky Notes tab.
    case notes
    /// The D-Day editor.
    case dDay
}
