import Foundation
import Testing
@testable import DeskCore

/// The names Save as Text File on Desktop gives memos (Erratum 31): the first line, made safe for a file name.
@Suite("Memo file names")
struct MemoFileNameTests {
    let day = DayKey("2026-10-18")!
    let note = MemoRef.note(NoteID(3))

    func name(_ text: String) -> String { MemoFileName.make(note, text: text, created: day) }

    /// What `FileOperator.createTextFile` takes: a plain, visible ".txt" name of at most 255 bytes, with no ":" and
    /// no control or format character, checked by scalar and byte (a mark can hide a "/" or "." in a grapheme).
    func isSafe(_ name: String) -> Bool {
        let u = name.unicodeScalars
        return DeskState.isPlainName(name) && !u.contains("/") && !u.contains(":") && name.utf8.count <= 255
            && name.utf8.count > 4 && name.utf8.suffix(4).elementsEqual(".txt".utf8) && name.utf8.first != UInt8(ascii: ".")
            && name == TextLayout.nfc(name) && !u.contains { [.control, .format].contains($0.properties.generalCategory) }
    }

    @Test("A note is named by its first line; Korean and emoji stay as they are")
    func firstLine() {
        #expect(name("우유 사기") == "우유 사기.txt")
        #expect(name("Call mom\nabout Sunday") == "Call mom.txt")
        #expect(name("\n\n   \n  택배 반품  \n둘째 줄") == "택배 반품.txt", "blank lines are skipped, the line trimmed")
        #expect(name("🍰 생일 🎂") == "🍰 생일 🎂.txt")
        #expect(name("Windows\r\nline") == "Windows.txt" && name("old Mac\rline") == "old Mac.txt")
        #expect(name("a\u{2028}b") == "a.txt", "a line separator ends the line")
    }

    @Test("\"/\" and \":\" become \"-\"; control and format characters go; a tab is a space")
    func unsafeCharacters() {
        #expect(name("10/18 회의: 3시") == "10-18 회의- 3시.txt")
        #expect(name("a/../../etc/passwd") == "a-..-..-etc-passwd.txt")
        #expect(name("tab\there") == "tab here.txt")
        #expect(name("nul\u{0}byte\u{7}bell") == "nulbytebell.txt")
        #expect(name("invoice\u{202E}txt.exe") == "invoicetxt.exe.txt", "no right-to-left override")
        #expect(name("zero\u{200B}width\u{FEFF}") == "zerowidth.txt", "a zero-width space and a BOM are format characters")
        // A combining mark makes "/" or ":" part of a grapheme; it is still replaced.
        #expect(name("a/\u{301}b:\u{301}c") == "a-\u{301}b-\u{301}c.txt")
        #expect(!name("👨\u{200D}👩\u{200D}👧").unicodeScalars.contains("\u{200D}"), "joiners are format characters")
    }

    @Test("No leading dot or space, no trailing space or dot: never a hidden name")
    func leadingDots() {
        #expect(name(".hidden") == "hidden.txt")
        #expect(name("...  .profile") == "profile.txt")
        #expect(name(" . . notes . . ") == "notes.txt")
        #expect(name("draft...") == "draft.txt")
        #expect(name("v1.2 notes") == "v1.2 notes.txt")
        // A line with nothing left is skipped; with no line left, a note is named by its day.
        #expect(name("...\nShopping") == "Shopping.txt")
        #expect(name("....") == "Memo 2026-10-18.txt")
        #expect(name("") == "Memo 2026-10-18.txt" && name(" \n\t\n ") == "Memo 2026-10-18.txt")
        #expect(name("\u{202E}\u{200E}") == "Memo 2026-10-18.txt")
        // A dot carrying a combining mark is still a leading dot (the name would be hidden).
        #expect(name(".\u{301}hidden").utf8.first != UInt8(ascii: "."))
        #expect(name("\u{3000}\u{A0}wide space") == "wide space.txt")
    }

    @Test("At most 40 graphemes of the line, and at most 255 bytes in all")
    func lengthLimits() {
        let long = String(repeating: "가나다라마", count: 20)
        let cut = name(long)
        #expect(cut == String(long.prefix(40)) + ".txt" && cut.count == 44)
        #expect(name(String(repeating: "a", count: 39) + " b") == String(repeating: "a", count: 39) + ".txt",
                "the cut leaves no trailing space")
        let emoji = String(repeating: "👩🏽‍💻", count: 50)
        #expect(name(emoji).count <= 44 && isSafe(name(emoji)))
        // A grapheme can take many bytes (combining marks): the name still fits 255 bytes.
        let heavy = String(repeating: "e" + String(repeating: "\u{301}", count: 30), count: 40)
        #expect(name(heavy).utf8.count <= 255 && isSafe(name(heavy)))
        let one = "e" + String(repeating: "\u{301}", count: 400)
        #expect(name(one) == "Memo 2026-10-18.txt", "a single grapheme too big for a name leaves no line")
    }

    @Test("A day page is named by its day, then its first line")
    func dayPages() {
        let page = MemoRef.day(DayKey("2026-10-30")!)
        #expect(MemoFileName.make(page, text: "회의 3시\n자료 준비", created: day) == "2026-10-30 회의 3시.txt")
        #expect(MemoFileName.make(page, text: "...", created: day) == "2026-10-30.txt")
        #expect(MemoFileName.make(page, text: ".env: x/y", created: day) == "2026-10-30 env- x-y.txt")
        let long = MemoFileName.make(page, text: String(repeating: "あ", count: 80), created: day)
        #expect(long == "2026-10-30 " + String(repeating: "あ", count: 40) + ".txt")
    }

    @Test("Every name is safe for the file operator, whatever the text", arguments: [
        "", ".", "..", "/", ":", "/:/", "...", " ", "\u{0}", "\u{FEFF}", "~", "-", "--help", "a\u{0}/b", "../x",
        "\u{1F}\u{7F}\u{85}x", "Ｆｕｌｌ／ｗｉｄｔｈ", "e\u{301}", "한\u{1100}\u{1161}", "x.txt", ".txt", "COM1",
        ".\u{301}", "/\u{301}", ":\u{301}.", ". \u{301}", "\u{301}\u{301}",
        String(repeating: "/", count: 300), String(repeating: "가", count: 300), String(repeating: "\u{301}", count: 50),
    ])
    func alwaysSafe(text: String) {
        for ref in [note, MemoRef.day(day)] {
            let n = MemoFileName.make(ref, text: text, created: day)
            #expect(isSafe(n), "\(ref) \(text.debugDescription) → \(n.debugDescription)")
        }
    }

    @Test("NFC: decomposed Hangul and accents are composed")
    func normalization() {
        #expect(name("\u{1112}\u{1161}\u{11AB}") == "한.txt")
        #expect(name("Cafe\u{301}") == "Café.txt" && name("Cafe\u{301}").unicodeScalars.count == 8)
    }

    @Test("Contents: a note's text, or a day page under its day, each with a final newline")
    func contents() {
        #expect(MemoFileName.contents(note, text: "우유 사기") == "우유 사기\n")
        #expect(MemoFileName.contents(.day(day), text: "회의 3시\n자료 준비") == "2026-10-18\n\n회의 3시\n자료 준비\n")
    }

    @Test("A note's day is the day of its creation in the user's time zone (an offset; the model reads no time zone)")
    func creationDay() {
        // 2026-10-18T23:30Z is the 19th in Seoul (+9 h); 2026-10-20T00:30Z is the 19th in California (−7 h).
        let late = Date(timeIntervalSince1970: 1_792_366_200), early = Date(timeIntervalSince1970: 1_792_456_200)
        #expect(MemoFileName.day(of: late).description == "2026-10-18")
        #expect(MemoFileName.day(of: late, utcOffset: 9 * 3600).description == "2026-10-19")
        #expect(MemoFileName.day(of: early).description == "2026-10-20")
        #expect(MemoFileName.day(of: early, utcOffset: -7 * 3600).description == "2026-10-19")
        // With no offset, UTC.
        #expect(MemoFileName.day(of: Date(timeIntervalSince1970: 0)).description == "1970-01-01")
        #expect(MemoFileName.day(of: Date(timeIntervalSince1970: 86_399)).description == "1970-01-01")
        #expect(MemoFileName.day(of: Date(timeIntervalSince1970: 86_400)).description == "1970-01-02")
        #expect(MemoFileName.day(of: Date(timeIntervalSince1970: -1)).description == "1969-12-31")
        // 2026-10-18T12:30:00Z
        #expect(MemoFileName.day(of: Date(timeIntervalSince1970: 1_792_326_600)).description == "2026-10-18")
        #expect(MemoFileName.day(of: Date(timeIntervalSince1970: .infinity)).description == "1970-01-01")
        #expect(MemoFileName.day(of: Date.distantFuture).description == "2999-12-31")
    }
}
