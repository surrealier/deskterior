import Foundation

/// Font-independent text layout for pixel labels: NFC normalization, Finder-style middle truncation and
/// line wrapping. Widths come from an `advance` closure (art px per `Character`), so the same code serves
/// `PixelFont` and tests. Every function NFC-normalizes its input first, so NFD file names lay out (and come
/// back) exactly like their precomposed form.
public enum TextLayout {
    /// Canonical composition (NFC). macOS file names are often decomposed (NFD); Galmuri has no conjoining
    /// jamo, so Hangul must be precomposed before it is measured or drawn.
    public static func nfc(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
    }

    /// Total advance of `s` (no normalization; callers pass NFC text).
    public static func width(_ s: some Sequence<Character>, advance: (Character) -> Int) -> Int {
        s.reduce(0) { $0 + advance($1) }
    }

    /// Shortens `s` to at most `maxWidth` by replacing its middle with `ellipsis`, Finder-style: the head and
    /// the tail are kept as balanced as possible, and the tail keeps the whole extension (".pdf") whenever it
    /// fits next to at least one head character. Returns the NFC string unchanged when it already fits, and
    /// `""` when not even the ellipsis fits.
    ///
    /// `extension` is the name's extension without the dot, as the file model knows it (`"pdf"`; `""` for
    /// folders and other names without one). It only counts when `s` ends with it. When nil, it is guessed
    /// conservatively: the text after the last dot, if that dot is not the first character and the text is 1–8
    /// characters with no whitespace, so dates and versions ("notes 10.14 with the team") are not extensions.
    public static func middleTruncate(
        _ s: String, maxWidth: Int, advance: (Character) -> Int, ellipsis: String = "…", extension ext: String? = nil
    ) -> String {
        let chars = Array(nfc(s))
        let widths = chars.map(advance)
        if widths.reduce(0, +) <= maxWidth { return String(chars) }

        let ellipsisWidth = width(ellipsis, advance: advance)
        let budget = maxWidth - ellipsisWidth
        if budget < 0 { return "" }

        var head = 0, tail = 0            // character counts taken from each end
        var headW = 0, tailW = 0

        // Seed the tail with the extension when it leaves room for a head character.
        let extCount = extensionLength(chars, ext.map { Array(nfc($0)) })
        if extCount > 0 {
            let extW = widths[(chars.count - extCount)...].reduce(0, +)
            if extW + widths[0] <= budget {
                tail = extCount
                tailW = extW
            }
        }

        // Grow the narrower side first; stop when neither side's next character fits.
        while head + tail < chars.count {
            let nextHead = widths[head]
            let nextTail = widths[chars.count - 1 - tail]
            let headFits = headW + tailW + nextHead <= budget
            let tailFits = headW + tailW + nextTail <= budget
            if headFits && (headW <= tailW || !tailFits) {
                headW += nextHead
                head += 1
            } else if tailFits {
                tailW += nextTail
                tail += 1
            } else {
                break
            }
        }
        return String(chars[0..<head]) + ellipsis + String(chars[(chars.count - tail)...])
    }

    /// Wraps `s` into at most `maxLines` lines of at most `maxWidth`. Lines break after spaces (which are
    /// dropped at the break), before or after any CJK/Hangul character, and — for a run with no break
    /// opportunity that is wider than a line — anywhere. If the text needs more lines, the last line holds the
    /// rest of the text middle-truncated (so the extension stays visible; `extension` as in `middleTruncate`).
    /// Leading spaces are kept only when they share the first line with text. Empty input gives no lines.
    public static func wrap(
        _ s: String, maxWidth: Int, maxLines: Int, advance: (Character) -> Int, extension ext: String? = nil
    ) -> [String] {
        var rest = Array(nfc(s))
        guard maxLines > 0, !rest.isEmpty else { return [] }

        var lines: [String] = []
        while !rest.isEmpty {
            if lines.count == maxLines - 1 {
                lines.append(middleTruncate(String(rest), maxWidth: maxWidth, advance: advance, extension: ext))
                break
            }
            if width(rest, advance: advance) <= maxWidth {
                lines.append(String(rest))
                break
            }
            let cut = breakIndex(rest, maxWidth: maxWidth, advance: advance)
            var line = rest[0..<cut]
            while let last = line.last, last == " " { line.removeLast() }
            if !line.isEmpty { lines.append(String(line)) }   // leading spaces that would fill a line are dropped
            rest = Array(rest[cut...].drop { $0 == " " })
        }
        return lines
    }

    /// True for Hangul, kana, CJK ideographs and CJK punctuation/full-width forms, where lines may break
    /// between any two characters.
    public static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x312F,
             0x3130...0x318F, 0x31A0...0x31FF, 0x3200...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F,
             0xAC00...0xD7AF, 0xD7B0...0xD7FF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF,
             0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    /// Longest extension guessed from a name: 1–8 characters after the final dot, no whitespace.
    private static let maxGuessedExtensionLength = 8

    /// Character count of the `.ext` suffix of `chars` (dot included), or 0 when there is none. `ext` nil
    /// guesses it (see `middleTruncate`); otherwise it must be what `chars` ends with, minus the dot.
    private static func extensionLength(_ chars: [Character], _ ext: [Character]?) -> Int {
        if var ext {
            if ext.first == "." { ext.removeFirst() }
            let n = ext.count + 1
            guard !ext.isEmpty, n < chars.count, chars[chars.count - n] == ".", chars.suffix(ext.count).elementsEqual(ext)
            else { return 0 }
            return n
        }
        guard let dot = chars.lastIndex(of: "."), dot > 0 else { return 0 }
        let n = chars.count - 1 - dot
        guard n >= 1, n <= maxGuessedExtensionLength, !chars[(dot + 1)...].contains(where: \.isWhitespace) else { return 0 }
        return n + 1
    }

    /// Where to end the next line of `chars`: the largest non-empty break opportunity
    /// whose prefix, minus trailing spaces, fits in `maxWidth`, moved past any following spaces. Without such
    /// an opportunity, the longest fitting prefix (at least one character).
    private static func breakIndex(_ chars: [Character], maxWidth: Int, advance: (Character) -> Int) -> Int {
        let n = chars.count
        var w = 0                         // width of chars[0..<i] without trailing spaces
        var pendingSpaces = 0
        var fit = 0
        var best = 0
        for i in 1...n {
            let c = chars[i - 1]
            if c == " " {
                pendingSpaces += advance(c)
            } else {
                w += pendingSpaces + advance(c)
                pendingSpaces = 0
            }
            if w > maxWidth { break }
            fit = i
            let opportunity = i == n || c == " " || chars[i] == " " || isCJK(c) || isCJK(chars[i])
            if opportunity && w > 0 { best = i }
        }
        guard best > 0 else { return max(1, fit) }
        var cut = best
        while cut < n && chars[cut] == " " { cut += 1 }
        return cut
    }
}
