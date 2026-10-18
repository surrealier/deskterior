import Foundation
import Testing
@testable import DeskCore

/// `memos.json` (Erratum 31): the golden decodes and re-encodes byte for byte, decoding degrades per field and per
/// note, a newer schema is refused, and what no book could hold is brought back into range.
@Suite("MemoDocument")
struct MemoDocumentTests {
    static let goldenName = "memos-v1.json"

    static func goldenURL(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true).appendingPathComponent(goldenName)
    }

    static func json(_ s: String) -> Data { Data(s.utf8) }

    static func date(_ s: String) -> Date { ISODate.parse(s)! }

    /// The book the golden holds: three notes (one dated), a day page and the D-Day.
    static func sample() -> MemoBook {
        var b = MemoBook()
        let created = date("2026-10-18T12:30:00Z")
        func note(_ n: Int, _ text: String, _ c: NoteColour, _ x: Int, _ y: Int, day: DayKey? = nil) {
            b.notes[NoteID(n)] = StickyNote(id: NoteID(n), text: text, colour: c, pos: ArtPoint(x, y), z: n - 1, day: day,
                                            created: created, edited: date("2026-10-18T12:31:02.250Z"))
        }
        note(1, "우유 사기", .yellow, 371, 67)
        note(2, "택배 반품", .pink, 401, 67)
        note(3, "Call mom\nabout Sunday", .sky, 371, 88, day: DayKey("2026-10-18"))
        b.pages[DayKey("2026-10-18")!] = "회의 3시\n자료 준비"
        b.dDay = DDay(day: DayKey("2026-10-30")!, title: "중간고사")
        b.nextNote = 4
        return b
    }

    @Test("The golden memos-v1.json decodes, and encoding it again gives the same bytes")
    func golden() throws {
        if TestSupport.environment("RECORD_SNAPSHOTS") == "1" {
            let doc = MemoDocument(book: Self.sample(), savedAt: Self.date("2026-10-18T12:31:03Z"), app: "0.3.0")
            try doc.encoded().write(to: Self.goldenURL(), options: .atomic)
        }
        let data = try Data(contentsOf: Self.goldenURL())
        let doc = try MemoDocument.decode(data)
        #expect(doc.schema == 1 && doc.app == "0.3.0" && doc.savedAt == Self.date("2026-10-18T12:31:03Z"))
        #expect(doc.nextNote == 4 && doc.notes.map(\.id) == [NoteID(1), NoteID(2), NoteID(3)])
        #expect(doc.notes[0].text == "우유 사기" && doc.notes[0].pos == ArtPoint(371, 67) && doc.notes[0].day == nil)
        #expect(doc.notes[2].day == DayKey("2026-10-18") && doc.notes[2].colour == .sky)
        #expect(doc.pages == ["2026-10-18": "회의 3시\n자료 준비"])
        #expect(doc.dDay == DDay(day: DayKey("2026-10-30")!, title: "중간고사"))
        #expect(doc.makeBook() == Self.sample())
        #expect(try doc.encoded() == data, "byte-stable")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"schema\" : 1") && text.contains("\"edited\" : \"2026-10-18T12:31:02.250Z\""))
        #expect(!text.contains("null") && text.components(separatedBy: "\"day\"").count == 3, "the dated note's and the D-Day's")
    }

    @Test("A book round-trips through the document exactly")
    func roundTrip() throws {
        var book = Self.sample()
        book.notes[NoteID(9)] = StickyNote(id: NoteID(9), text: "", colour: .cream, pos: ArtPoint(18, 115), z: 3,
                                           created: Self.date("2026-10-19T08:00:00.125Z"), edited: Self.date("2026-10-19T08:00:00.125Z"))
        book.nextNote = 12
        let data = try MemoDocument(book: book, savedAt: ModelFixture.t0).encoded()
        let back = try MemoDocument.decode(data)
        #expect(back.makeBook() == book && back.savedAt == ModelFixture.t0)
        #expect(back.notes.map(\.id) == [NoteID(1), NoteID(2), NoteID(3), NoteID(9)], "sorted by number")
        #expect(try MemoDocument.decode(back.encoded()) == back)
        #expect(try MemoDocument.decode(MemoDocument(book: MemoBook(), savedAt: ModelFixture.t0).encoded()).makeBook() == MemoBook())
    }

    @Test("Decoding degrades per field and per note")
    func lenient() throws {
        let doc = try MemoDocument.decode(Self.json("""
            {"schema": 1, "app": 3, "savedAt": "yesterday", "nextNote": "four", "future": {"x": 1},
             "notes": [
               {"id": "N1", "pos": [371, 67], "text": "ok", "colour": "plaid", "z": "top", "day": "2026-02-30",
                "created": "never"},
               {"id": "N2", "text": "no position"},
               {"id": "N03", "pos": [1, 2]},
               {"id": "N4", "pos": [1]},
               {"id": "N5", "pos": [401, 67], "text": 7}
             ],
             "pages": {"2026-10-18": "page", "2026-13-01": "bad day", "2026-10-19": 5, "2026-10-20": ""},
             "dDay": {"day": "someday", "title": "x"}}
            """))
        #expect(doc.app == "" && doc.savedAt == nil)
        #expect(doc.notes.map(\.id) == [NoteID(1), NoteID(5)])
        let n1 = doc.notes[0]
        #expect(n1.text == "ok" && n1.colour == .yellow && n1.day == nil && n1.created == Date(timeIntervalSince1970: 0))
        #expect(doc.notes[1].text == "")
        #expect(doc.pages == ["2026-10-18": "page"] && doc.dDay == nil && doc.nextNote == 6)
        // Damage to the whole: notes that are not a list are none; a file that is not an object fails.
        #expect(try MemoDocument.decode(Self.json(#"{"schema": 1, "notes": {"N1": 1}}"#)).notes.isEmpty)
        #expect(throws: (any Error).self) { try MemoDocument.decode(Self.json("[1]")) }
        #expect(throws: (any Error).self) { try MemoDocument.decode(Self.json("{\"schema\": 1, ")) }
        #expect(throws: Migrations.Failure.missingSchema) { try MemoDocument.decode(Self.json(#"{"notes": []}"#)) }
    }

    @Test("A newer schema is refused, so a newer file is never overwritten")
    func newerSchema() {
        #expect(throws: Migrations.Failure.newerSchema(2)) {
            try MemoDocument.decode(Self.json(#"{"schema": 2, "notes": [], "nextNote": 1}"#))
        }
    }

    @Test("Sanitize: clean text, the 24 frontmost notes renumbered densely, notes on the felt, ids never reused")
    func sanitize() throws {
        var doc = MemoDocument(book: MemoBook(), savedAt: ModelFixture.t0)
        doc.nextNote = 2
        doc.notes = (1...30).map { n in
            StickyNote(id: NoteID(n), text: "n\(n)\r\n", colour: .lime, pos: ArtPoint(371, 67), z: 100 - 3 * (n % 10),
                       created: ModelFixture.t0, edited: ModelFixture.t0)
        }
        doc.notes.append(StickyNote(id: NoteID(7), text: "duplicate", colour: .pink, pos: ArtPoint(0, 0), z: 999,
                                    created: ModelFixture.t0, edited: ModelFixture.t0))
        doc.notes[0].pos = ArtPoint(-50, 400)
        doc.notes[1].pos = ArtPoint(380, 100)
        doc.pages = ["2026-10-18": "a\u{0}b\r\nc", "18 Oct": "x", "2026-10-19": "\u{7}"]
        doc.dDay = DDay(day: DayKey("2026-10-30")!, title: String(repeating: "가", count: 30))
        let s = try MemoDocument.decode(doc.encoded())
        #expect(s.notes.count == MemoBook.maxNotes && Set(s.notes.map(\.id)).count == MemoBook.maxNotes)
        // The six dropped are the hindmost: z 100 − 3·9 for n ≡ 9 (mod 10) and the back of n ≡ 8.
        let dropped = Set((1...30).map(NoteID.init)).subtracting(s.notes.map(\.id))
        #expect(dropped == [NoteID(9), NoteID(19), NoteID(29), NoteID(8), NoteID(18), NoteID(28)])
        #expect(Set(s.notes.map(\.z)) == Set(0..<MemoBook.maxNotes))
        let byZ = s.notes.sorted { $0.z < $1.z }
        #expect(byZ.map(\.id) == byZ.sorted { ($0.z, $0.id) < ($1.z, $1.id) }.map(\.id))
        #expect(s.notes.first { $0.id == NoteID(7) }?.text == "n7\n", "the first note of an id is kept")
        #expect(s.notes.allSatisfy { $0.text.hasPrefix("n") && !$0.text.contains("\r") })
        for n in s.notes {
            let r = PartitionLayout.noteRect(at: n.pos)
            #expect(PartitionLayout.faces.contains { $0.contains(r) }, "\(n.id) at \(n.pos)")
        }
        #expect(s.notes.first { $0.id == NoteID(1) }?.pos == ArtPoint(15, 140))
        #expect(s.notes.first { $0.id == NoteID(2) }?.pos == ArtPoint(380, 88), "the nearer face, the tower")
        #expect(s.pages == ["2026-10-18": "ab\nc"] && s.dDay?.title.count == MemoBook.maxTitle)
        #expect(s.nextNote == 31 && s.makeBook().nextNoteID == NoteID(31))
    }

    @Test("Absurd numbers in a memos.json that parses are brought back into range: no launch traps on them")
    func absurdNumbers() throws {
        // A hand edit or a merge tool: an id at Int.max (its next would overflow), a position at Int.min (its distance
        // to the felt would), two coordinates whose distances overflow when added, and a next note at Int.max.
        let doc = try MemoDocument.decode(Self.json(#"""
            {"schema": 1, "nextNote": 9223372036854775807, "notes": [
              {"id": "N9223372036854775807", "text": "big id", "pos": [371, 67], "z": 0},
              {"id": "N2", "text": "far left", "pos": [-9223372036854775808, 0], "z": 1},
              {"id": "N3", "text": "far away", "pos": [-5000000000000000000, -5000000000000000000], "z": 2}
            ]}
            """#))
        #expect(doc.notes.map(\.id) == [NoteID(2), NoteID(3), NoteID(4)], "the far-off id is renumbered after the others")
        #expect(doc.notes.map(\.text) == ["far left", "far away", "big id"], "no note is lost")
        #expect(doc.nextNote == 5 && doc.nextNote <= MemoDocument.maxNoteNumber)
        for n in doc.notes {
            let r = PartitionLayout.noteRect(at: n.pos)
            #expect(PartitionLayout.faces.contains { $0.contains(r) }, "\(n.id) at \(n.pos)")
        }
        // New notes go on as usual.
        var s = DeskState()
        s.memos = doc.makeBook()
        let id = s.memos.nextNoteID
        _ = reduce(&s, .addNote(NewNote(id: id, text: "next", colour: .lime), session: nil), ReduceEnv(now: ModelFixture.t0))
        #expect(id == NoteID(5) && s.memos.notes[id]?.text == "next" && s.memos.nextNoteID == NoteID(6))
        // A next note number no book could reach is ignored on its own too.
        let next = try MemoDocument.decode(Self.json(#"{"schema": 1, "nextNote": 9223372036854775807, "notes": []}"#))
        #expect(next.nextNote == 1)
    }
}
