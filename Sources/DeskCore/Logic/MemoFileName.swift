/// The name Save as Text File on Desktop gives a memo (Erratum 31): its first line (NFC, "/" and ":" as "-", no
/// leading dot, at most 40 graphemes) + ".txt", "Memo YYYY-MM-DD.txt" for a note with an empty first line, and
/// "YYYY-MM-DD <first line>.txt" for a day page. Always a plain name (`DeskState.isPlainName`).
public enum MemoFileName {
    public static func make(_ ref: MemoRef, text: String, created: DayKey) -> String {
        // Step 0 stub: Track E (spec §6).
        switch ref {
        case .note: "Memo \(created).txt"
        case let .day(day): "\(day).txt"
        }
    }
}
