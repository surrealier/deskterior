import Foundation

/// `memos.json`, schema 1 (Erratum 31): the sticky notes, the day pages and the D-Day, kept apart from `desk.json`
/// so they survive Reset Layout, folder switches and a downgrade. `StateStore.loadMemos` / `saveMemos` read and
/// write it. Keys are sorted, notes by id number, a note's `day` is left out when it has none, and dates are
/// `DeskDocument`'s millisecond ISO strings. Decoding is lenient per field and per note, and brings what no book
/// could hold back into range (`sanitized`); a newer schema is refused, so a newer file is never overwritten.
public struct MemoDocument: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int = MemoDocument.currentSchema
    public var app: String = DeskCore.version
    public var savedAt: Date?
    public var nextNote = 1
    /// Sorted by id number.
    public var notes: [StickyNote] = []
    /// Day pages by "YYYY-MM-DD".
    public var pages: [String: String] = [:]
    public var dDay: DDay?

    public init(book: MemoBook, savedAt: Date, app: String = DeskCore.version) {
        self.app = app
        self.savedAt = savedAt
        nextNote = book.nextNote
        notes = book.notes.values.sorted { $0.id < $1.id }
        pages = Dictionary(uniqueKeysWithValues: book.pages.map { ($0.key.description, $0.value) })
        dDay = book.dDay
    }

    /// The book this document holds.
    public func makeBook() -> MemoBook {
        var book = MemoBook()
        for n in notes where book.notes[n.id] == nil { book.notes[n.id] = n }
        for (day, text) in pages { if let d = DayKey(day), !text.isEmpty { book.pages[d] = text } }
        book.dDay = dDay
        book.nextNote = max(nextNote, (notes.map(\.id.number).max() ?? 0) + 1)
        return book
    }

    /// Decodes `data`: a schema newer than this build's throws `Migrations.Failure.newerSchema` (the file is kept
    /// as it is); then every field degrades on its own, and the result is `sanitized`.
    public static func decode(_ data: Data) throws -> MemoDocument {
        let n = try Migrations.schema(of: data)
        guard n <= currentSchema else { throw Migrations.Failure.newerSchema(n) }
        return try DeskDocument.makeDecoder().decode(MemoDocument.self, from: data).sanitized()
    }

    /// Pretty, key-sorted JSON (stable diffs).
    public func encoded() throws -> Data {
        try DeskDocument.makeEncoder().encode(self)
    }

    // MARK: Sanitize

    /// The highest note number a file may hold, and the farthest a note's position may be from the room (core px):
    /// far beyond any real book, and far from overflowing the arithmetic on them (Errata 25).
    static let maxNoteNumber = 1_000_000_000
    static let maxCoordinate = 100_000

    /// `self` as a book can hold it: every text and title clean (`MemoBook.clean`), no page under a key that is not
    /// a day or with no text, one note per id, a note numbered past `maxNoteNumber` (a hand edit) renumbered after the
    /// others, the 24 frontmost notes, z numbered densely back to front (by z, then id), every note inside a felt
    /// face (the nearest), and a next note number past every id (a stored one past `maxNoteNumber` is ignored).
    public func sanitized() -> MemoDocument {
        var d = self
        var seen = Set<NoteID>()
        var kept = notes.filter { seen.insert($0.id).inserted }
        let highest = kept.lazy.map(\.id.number).filter { $0 <= Self.maxNoteNumber }.max() ?? 0
        var next = max(1, nextNote <= Self.maxNoteNumber ? nextNote : 1, highest + 1)
        for i in kept.indices.sorted(by: { kept[$0].id < kept[$1].id }) where kept[i].id.number > Self.maxNoteNumber {
            kept[i].id = NoteID(next)
            next += 1
        }
        kept.sort { ($0.z, $0.id) > ($1.z, $1.id) }
        kept = Array(kept.prefix(MemoBook.maxNotes)).sorted { ($0.z, $0.id) < ($1.z, $1.id) }
        for i in kept.indices {
            kept[i].z = i
            kept[i].text = MemoBook.clean(kept[i].text)
            kept[i].pos = Self.onFelt(kept[i].pos)
        }
        d.notes = kept.sorted { $0.id < $1.id }
        d.pages = [:]
        for (key, text) in pages {
            guard let day = DayKey(key) else { continue }
            let clean = MemoBook.clean(text)
            if !clean.isEmpty { d.pages[day.description] = clean }
        }
        d.dDay = dDay.map { DDay(day: $0.day, title: MemoBook.clean($0.title, limit: MemoBook.maxTitle)) }
        d.nextNote = next
        return d
    }

    /// `p` moved the least that puts a note wholly on a felt face.
    static func onFelt(_ p: ArtPoint) -> ArtPoint {
        let m = Self.maxCoordinate
        let p = ArtPoint(min(max(p.x, -m), m), min(max(p.y, -m), m))
        let size = PartitionLayout.noteSize
        let spots = PartitionLayout.faces.map { f in
            ArtPoint(min(max(p.x, f.minX), f.maxX - size.w), min(max(p.y, f.minY), f.maxY - size.h))
        }
        return spots.min { a, b in
            let da = abs(a.x - p.x) + abs(a.y - p.y), db = abs(b.x - p.x) + abs(b.y - p.y)
            return da < db
        }!
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case schema, app, savedAt, nextNote, notes, pages, dDay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        app = c.lenient(.app, default: "")
        savedAt = c.lenient(.savedAt, default: nil)
        nextNote = c.lenient(.nextNote, default: 1)
        notes = c.lenient(.notes, default: Lossy<StickyNote>()).elements
        pages = c.lenient(.pages, default: [String: Lenient<String>]()).compactMapValues(\.value)
        dDay = c.lenient(.dDay, default: nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(app, forKey: .app)
        try c.encodeIfPresent(savedAt, forKey: .savedAt)
        try c.encode(nextNote, forKey: .nextNote)
        try c.encode(notes, forKey: .notes)
        try c.encode(pages, forKey: .pages)
        try c.encodeIfPresent(dDay, forKey: .dDay)
    }
}

/// A value that decodes to nil instead of failing, so one bad entry of a dictionary loses only itself.
struct Lenient<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}
