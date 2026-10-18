import Testing
@testable import DeskCore

/// The memo model's value types (Erratum 31): day keys, note ids and colours, and the book's text rule and calendar
/// marks.
@Suite("DayKey and MemoBook")
struct DayKeyTests {
    @Test("Day keys parse and print YYYY-MM-DD exactly, and only real dates from 1900 to 2999")
    func parseAndFormat() throws {
        let d = try #require(DayKey("2026-10-18"))
        #expect(d.year == 2026 && d.month == 10 && d.day == 18 && d.description == "2026-10-18")
        #expect(DayKey(year: 1900, month: 1, day: 1)?.description == "1900-01-01")
        #expect(DayKey(year: 2999, month: 12, day: 31)?.description == "2999-12-31")
        for bad in ["2026-1-18", "2026-10-8", "26-10-18", "2026-13-01", "2026-00-10", "2026-04-31", "2026-10-00",
                    "1899-12-31", "3000-01-01", "2026-10-18T", " 2026-10-18", "2026/10/18", "２０２６-10-18", "+026-10-18", ""] {
            #expect(DayKey(bad) == nil, "\(bad)")
        }
        #expect(DayKey(year: 2026, month: 2, day: 29) == nil && DayKey(year: 1899, month: 12, day: 31) == nil)
        #expect(DayKey("2026-01-31")! < d && d < DayKey("2026-10-19")! && DayKey("2025-12-31")! < DayKey("2026-01-01")!)
    }

    @Test("Leap years: every fourth year, not centuries, but every fourth century")
    func leapYears() {
        #expect(DayKey(year: 2024, month: 2, day: 29) != nil && DayKey(year: 2000, month: 2, day: 29) != nil)
        #expect(DayKey(year: 2023, month: 2, day: 29) == nil && DayKey(year: 1900, month: 2, day: 29) == nil)
        #expect(DayKey(year: 2100, month: 2, day: 29) == nil && DayKey(year: 2400, month: 2, day: 29) != nil)
        #expect(DayKey("2024-02-28")!.adding(days: 1).description == "2024-02-29")
        #expect(DayKey("2023-02-28")!.adding(days: 1).description == "2023-03-01")
    }

    @Test("days(until:) and adding(days:) agree across months and years, and clamp to the range")
    func dayArithmetic() throws {
        let d = try #require(DayKey("2026-10-18"))
        #expect(d.days(until: DayKey("2026-10-30")!) == 12)
        #expect(DayKey("2026-10-30")!.days(until: d) == -12)
        #expect(DayKey("2026-12-31")!.days(until: DayKey("2027-01-01")!) == 1)
        #expect(DayKey("2024-01-01")!.days(until: DayKey("2025-01-01")!) == 366)
        #expect(DayKey("2023-01-01")!.days(until: DayKey("2024-01-01")!) == 365)
        #expect(DayKey("1900-01-01")!.days(until: DayKey("2000-01-01")!) == 36_524)
        for n in stride(from: -1500, through: 1500, by: 7) {
            let e = d.adding(days: n)
            #expect(d.days(until: e) == n, "\(n)")
            #expect(DayKey(e.description) == e)
        }
        #expect(d.adding(days: 0) == d)
        #expect(DayKey("1900-01-02")!.adding(days: -10).description == "1900-01-01")
        #expect(DayKey("2999-12-30")!.adding(days: 10).description == "2999-12-31")
    }

    @Test("Weekdays agree with WallTime's for every day of 2025 to 2027 (0 = Sunday)")
    func weekdays() throws {
        var d = try #require(DayKey("2025-01-01"))
        while d.year < 2028 {
            #expect(d.weekday == d.wallTime.weekday, "\(d)")
            #expect(d.wallTime.hour == 0 && d.wallTime.minute == 0 && DayKey(d.wallTime) == d)
            d = d.adding(days: 1)
        }
        #expect(DayKey("2026-10-18")!.weekday == 0, "a Sunday")
        #expect(DayKey("1900-01-01")!.weekday == 1 && DayKey("2000-01-01")!.weekday == 6)
    }

    @Test("A wall reading gives its day, clamped to the month and the range")
    func fromWallTime() {
        #expect(DayKey(WallTime(year: 2026, month: 10, day: 18, hour: 23, minute: 59)).description == "2026-10-18")
        #expect(DayKey(WallTime(year: 2026, month: 2, day: 31, hour: 9, minute: 0)).description == "2026-02-28")
        #expect(DayKey(WallTime(year: 1066, month: 10, day: 14, hour: 9, minute: 0)).description == "1900-10-14")
        #expect(DayKey(WallTime(year: 9999, month: 12, day: 31, hour: 9, minute: 0)).description == "2999-12-31")
    }

    @Test("Day keys and note ids are JSON strings; malformed ones do not decode")
    func codable() throws {
        #expect(try TestSupport.encodeJSON(DayKey("2026-10-18")!) == "\"2026-10-18\"")
        #expect(try TestSupport.decodeJSON(DayKey.self, "\"2026-10-30\"") == DayKey("2026-10-30"))
        #expect(throws: (any Error).self) { try TestSupport.decodeJSON(DayKey.self, "\"2026-02-30\"") }
        #expect(try TestSupport.encodeJSON(NoteID(3)) == "\"N3\"")
        #expect(try TestSupport.decodeJSON(NoteID.self, "\"N12\"") == NoteID(12))
        #expect(throws: (any Error).self) { try TestSupport.decodeJSON(NoteID.self, "\"N03\"") }
        #expect(try TestSupport.decodeJSON(NoteColour.self, "\"magenta\"") == .yellow, "an unknown colour reads as yellow")
        #expect(try TestSupport.decodeJSON(NoteColour.self, "\"sky\"") == .sky)
    }

    @Test("Note ids are N and a positive number; they order by number")
    func noteIDs() {
        #expect(NoteID(7).raw == "N7" && NoteID(7).number == 7 && NoteID(7).description == "N7")
        #expect(NoteID(raw: "N12") == NoteID(12))
        for bad in ["N", "N0", "N03", "n3", "N-1", "M3", "N3a", "N 3", "N３", ""] { #expect(NoteID(raw: bad) == nil, "\(bad)") }
        #expect(NoteID(2) < NoteID(10) && !(NoteID(10) < NoteID(2)))
        #expect(NoteColour.allCases.map(\.title) == ["Yellow", "Pink", "Sky", "Lime", "Orange", "Cream"])
    }

    @Test("A note's JSON: [x, y] for its spot, no day when undated; fields degrade on their own")
    func noteJSON() throws {
        let t = ModelFixture.t0
        let note = StickyNote(id: NoteID(1), text: "우유 사기", colour: .pink, pos: ArtPoint(371, 67), z: 2, created: t, edited: t)
        let json = try TestSupport.encodeJSON(note)
        #expect(json.contains("\"pos\":[371,67]") && !json.contains("\"day\""), "\(json)")
        #expect(try TestSupport.decodeJSON(StickyNote.self, json) == note)
        var dated = note
        dated.day = DayKey("2026-10-18")
        #expect(try TestSupport.decodeJSON(StickyNote.self, try TestSupport.encodeJSON(dated)) == dated)
        let loose = try TestSupport.decodeJSON(StickyNote.self, #"{"id":"N4","pos":[18,115],"colour":"teal","day":"2026-02-30","z":"x"}"#)
        #expect(loose.id == NoteID(4) && loose.pos == ArtPoint(18, 115) && loose.colour == .yellow)
        #expect(loose.text == "" && loose.day == nil && loose.z == 0)
        #expect(throws: (any Error).self) { try TestSupport.decodeJSON(StickyNote.self, #"{"id":"N4","text":"x"}"#) }
        #expect(throws: (any Error).self) { try TestSupport.decodeJSON(StickyNote.self, #"{"id":"N4","pos":[1]}"#) }
    }

    @Test("clean: NFC, CRLF and CR as LF, control characters gone but newline and tab, at most the limit in graphemes")
    func clean() {
        #expect(MemoBook.clean("a\r\nb\rc\n") == "a\nb\nc\n")
        #expect(MemoBook.clean("a\u{0007}b\u{0000}c\td\u{001B}") == "abc\td")
        #expect(MemoBook.clean("e\u{0301}").unicodeScalars.count == 1, "NFC")
        #expect(MemoBook.clean("\u{1112}\u{1161}\u{11AB}") == "한", "decomposed Hangul is composed")
        #expect(MemoBook.clean("e\u{0007}\u{0301}") == "é", "a control between a letter and its accent goes first")
        let thumbs = String(repeating: "👍🏽", count: 1200)
        #expect(MemoBook.clean(thumbs).count == MemoBook.maxText && MemoBook.clean(thumbs).hasPrefix("👍🏽"))
        #expect(MemoBook.clean(String(repeating: "가", count: 30), limit: MemoBook.maxTitle).count == 24)
        #expect(MemoBook.clean("회의 3시\n자료 준비") == "회의 3시\n자료 준비")
        #expect(MemoBook.clean("") == "" && MemoBook.clean("abc", limit: 0) == "")
    }

    @Test("Calendar marks: a page, a dated note, the D-Day, for the month asked only")
    func marks() {
        let t = ModelFixture.t0
        var book = MemoBook()
        book.pages[DayKey("2026-10-18")!] = "회의 3시"
        book.pages[DayKey("2026-10-19")!] = ""
        book.pages[DayKey("2026-11-01")!] = "next month"
        for (i, day) in [DayKey("2026-10-18"), DayKey("2026-10-20"), nil, DayKey("2025-10-20")].enumerated() {
            let id = NoteID(i + 1)
            book.notes[id] = StickyNote(id: id, text: "", colour: .yellow, pos: ArtPoint(371, 67), z: i, day: day,
                                        created: t, edited: t)
        }
        book.dDay = DDay(day: DayKey("2026-10-30")!, title: "중간고사")
        #expect(book.marks(year: 2026, month: 10) == [18: [.memo, .note], 20: [.note], 30: [.dDay]])
        #expect(book.marks(year: 2026, month: 11) == [1: [.memo]])
        #expect(book.marks(year: 2026, month: 9).isEmpty)
        #expect(book.notes(on: DayKey("2026-10-20")!).map(\.id) == [NoteID(2)])
    }

    @Test("Notes stack by z then id; the next id is past every id in use")
    func ordering() {
        let t = ModelFixture.t0
        var book = MemoBook()
        #expect(book.nextNoteID == NoteID(1))
        for (n, z) in [(3, 1), (1, 1), (2, 0)] {
            book.notes[NoteID(n)] = StickyNote(id: NoteID(n), text: "", colour: .sky, pos: ArtPoint(0, 0), z: z,
                                               created: t, edited: t)
        }
        #expect(book.backToFront.map(\.id) == [NoteID(2), NoteID(1), NoteID(3)])
        book.nextNote = 9
        #expect(book.nextNoteID == NoteID(9))
        book.nextNote = 2
        #expect(book.nextNoteID == NoteID(4), "ids are never reused")
    }

    @Test("D-Day card text: D-n before, D-DAY on the day, D+n after, capped at 999")
    func dDayText() {
        #expect(PartitionArt.ddayText(days: 12) == "D-12" && PartitionArt.ddayText(days: 0) == "D-DAY")
        #expect(PartitionArt.ddayText(days: -3) == "D+3" && PartitionArt.ddayText(days: 5000) == "D-999")
        #expect(PartitionArt.ddayText(days: -5000) == "D+999" && PartitionArt.ddayText(days: Int.min) == "D+999")
    }
}
