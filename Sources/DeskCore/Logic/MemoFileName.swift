import Foundation

/// The name Save as Text File on Desktop gives a memo (Erratum 31): its first line (NFC, "/" and ":" as "-", no
/// leading dot, at most 40 graphemes) + ".txt", "Memo YYYY-MM-DD.txt" for a note with an empty first line, and
/// "YYYY-MM-DD <first line>.txt" for a day page. Always a plain, visible name (`DeskState.isPlainName`, no leading
/// dot, no control or format characters, at most 255 UTF-8 bytes), so `FileOperator.createTextFile` takes it.
public enum MemoFileName {
    /// The most graphemes of the memo's line a name keeps.
    public static let maxLine = 40
    /// The most UTF-8 bytes a file name may take (APFS, HFS+).
    public static let maxNameBytes = 255
    /// The most UTF-8 bytes a saved memo may take (`FileOperator.maxTextFileBytes` refuses more).
    public static let maxContentBytes = 64 * 1024
    static let suffix = ".txt"

    /// `ref`'s file name for `text`; `created` names a note whose text gives no line (a day page is named by its day).
    public static func make(_ ref: MemoRef, text: String, created: DayKey) -> String {
        let prefix: String = switch ref {
        case .note: ""
        case let .day(day): "\(day) "
        }
        // The line fits the name with its prefix and ".txt" (a grapheme can take many bytes).
        var line = firstLine(text)
        while !line.isEmpty, (prefix + line + suffix).utf8.count > maxNameBytes { line.removeLast() }
        line = trimmed(line)
        let stem: String = switch ref {
        case .note: line.isEmpty ? "Memo \(created)" : line
        case let .day(day): line.isEmpty ? "\(day)" : prefix + line
        }
        return TextLayout.nfc(stem) + suffix
    }

    /// The contents Save as Text File writes for a memo: a note's text, or a day page under its day; LF line ends
    /// (the book keeps them so) and a final newline.
    public static func contents(_ ref: MemoRef, text: String) -> String {
        switch ref {
        case .note: text + "\n"
        case let .day(day): "\(day)\n\n" + text + "\n"
        }
    }

    /// The day a note created at `date` was made, `utcOffset` seconds east of UTC (`ReduceEnv.utcOffset`: the model
    /// reads no calendar or time zone). The offset is today's, so near midnight across a daylight-saving change the
    /// day can be off by one.
    public static func day(of date: Date, utcOffset: Int = 0) -> DayKey {
        let epoch = DayKey(year: 1970, month: 1, day: 1)!
        let t = date.timeIntervalSince1970 + Double(utcOffset)
        guard t.isFinite else { return epoch }
        let days = (t / 86400).rounded(.down)
        return epoch.adding(days: Int(max(min(days, 1e7), -1e7)))
    }

    // MARK: Inside

    /// The first line of `text` that keeps anything once made safe for a name (`sanitized`); "" when none does.
    static func firstLine(_ text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let safe = sanitized(String(line))
            if !safe.isEmpty { return safe }
        }
        return ""
    }

    /// One line made safe for a file name: NFC; control characters (Cc, NUL among them; a tab becomes a space) and
    /// format characters (Cf: bidi overrides, zero-width joiners, a BOM) removed; "/" and ":" as "-" (Finder shows
    /// one as the other); leading dots and spaces stripped (a hidden or blank-looking name), at most `maxLine`
    /// graphemes, trailing spaces and dots trimmed. Dots and spaces are told apart by scalar, not by grapheme, so a
    /// dot carrying a combining mark (".\u{301}") still counts as a leading dot.
    static func sanitized(_ line: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in TextLayout.nfc(line).unicodeScalars {
            switch u.properties.generalCategory {
            case .control: if u == "\t" { scalars.append(" ") }
            case .format: break
            default: scalars.append(u == "/" || u == ":" ? "-" : u)
            }
        }
        while let u = scalars.first, isDotOrSpace(u) { scalars.removeFirst() }
        return trimmed(String(TextLayout.nfc(String(scalars)).prefix(maxLine)))
    }

    /// `s` without trailing spaces and dots (by scalar).
    static func trimmed(_ s: String) -> String {
        var scalars = s.unicodeScalars
        while let u = scalars.last, isDotOrSpace(u) { scalars.removeLast() }
        return String(scalars)
    }

    private static func isDotOrSpace(_ u: Unicode.Scalar) -> Bool { u == "." || u.properties.isWhitespace }
}
