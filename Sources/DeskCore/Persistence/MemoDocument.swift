import Foundation

/// `memos.json`, schema 1 (Erratum 31): the sticky notes, the day pages and the D-Day, kept apart from `desk.json`
/// so they survive Reset Layout, folder switches and a downgrade. `StateStore.loadMemos` / `saveMemos` read and
/// write it.
///
/// Step 0 stub: Track A (spec §4.5). It round-trips a book with `DeskDocument`'s encoder and decoder; lenient
/// per-field decoding (`Lossy<StickyNote>`), the sanitize rules and the newer-schema refusal are not here yet.
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

    public init(book: MemoBook, savedAt: Date) {
        self.savedAt = savedAt
        nextNote = book.nextNote
        notes = book.notes.values.sorted { $0.id < $1.id }
        pages = Dictionary(uniqueKeysWithValues: book.pages.map { ($0.key.description, $0.value) })
        dDay = book.dDay
    }

    /// The book this document holds.
    public func makeBook() -> MemoBook {
        var book = MemoBook()
        for n in notes { book.notes[n.id] = n }
        for (day, text) in pages { if let d = DayKey(day), !text.isEmpty { book.pages[d] = text } }
        book.dDay = dDay
        book.nextNote = max(nextNote, (notes.map(\.id.number).max() ?? 0) + 1)
        return book
    }

    public static func decode(_ data: Data) throws -> MemoDocument {
        try DeskDocument.makeDecoder().decode(MemoDocument.self, from: data) // Step 0 stub: Track A.
    }

    /// Pretty, key-sorted JSON (stable diffs).
    public func encoded() throws -> Data {
        try DeskDocument.makeEncoder().encode(self)
    }
}
