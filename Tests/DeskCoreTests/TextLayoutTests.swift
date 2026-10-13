import Testing
@testable import DeskCore

@Suite("TextLayout")
struct TextLayoutTests {
    /// Galmuri9-like advances: CJK 10, space and "." 4, ellipsis 10, everything else 6.
    static func advance(_ c: Character) -> Int {
        if TextLayout.isCJK(c) || c == "…" { return 10 }
        if c == " " || c == "." { return 4 }
        return 6
    }

    func width(_ s: String) -> Int { TextLayout.width(s, advance: Self.advance) }

    let reportNFC = "보고서 final.pdf"
    var reportNFD: String { TestSupport.nfd(reportNFC) }

    @Test("NFC composes decomposed Hangul")
    func nfc() {
        #expect(reportNFD.unicodeScalars.count > reportNFC.unicodeScalars.count)
        #expect(reportNFD.unicodeScalars.contains { (0x1100...0x11FF).contains($0.value) })
        let composed = TextLayout.nfc(reportNFD)
        #expect(Array(composed.unicodeScalars) == Array(reportNFC.unicodeScalars))
        #expect(!composed.unicodeScalars.contains { (0x1100...0x11FF).contains($0.value) })
        #expect(TextLayout.nfc("e\u{301}") == "\u{E9}")
    }

    @Test("Fitting strings come back unchanged (NFC)")
    func fits() {
        #expect(TextLayout.middleTruncate(reportNFC, maxWidth: 200, advance: Self.advance) == reportNFC)
        let fromNFD = TextLayout.middleTruncate(reportNFD, maxWidth: 200, advance: Self.advance)
        #expect(Array(fromNFD.unicodeScalars) == Array(reportNFC.unicodeScalars))
        #expect(TextLayout.middleTruncate("", maxWidth: 0, advance: Self.advance) == "")
    }

    @Test("Balanced middle truncation without an extension")
    func balanced() {
        let s = "abcdefghijklmnopqrstuvwxyz"
        #expect(TextLayout.middleTruncate(s, maxWidth: 70, advance: Self.advance) == "abcde…vwxyz")
        #expect(TextLayout.middleTruncate(s, maxWidth: 71, advance: Self.advance) == "abcde…vwxyz")
        #expect(TextLayout.middleTruncate(s, maxWidth: 76, advance: Self.advance) == "abcdef…vwxyz")
    }

    @Test("Truncation keeps the whole extension")
    func keepsExtension() {
        let s = "abcdefghijklmnopqrstuvwxyz.txt"
        let t = TextLayout.middleTruncate(s, maxWidth: 70, advance: Self.advance)
        #expect(t == "abcde…z.txt")
        #expect(width(t) <= 70)

        let long = "보고서 최종 최최종 정말 마지막 final.pdf"
        // Budget 40 − 10 = 30 cannot hold ".pdf" (22) plus "보" (10): balanced fallback.
        #expect(TextLayout.middleTruncate(long, maxWidth: 40, advance: Self.advance) == "보…pdf")
        for maxWidth in stride(from: 42, through: 200, by: 7) {
            let r = TextLayout.middleTruncate(long, maxWidth: maxWidth, advance: Self.advance)
            #expect(width(r) <= maxWidth)
            #expect(r.hasSuffix(".pdf"), "\(r)")
            #expect(r.hasPrefix("보"), "\(r)")
            #expect(r.contains("…"))
        }
        // NFD input truncates to the same NFC result.
        let nfd = TestSupport.nfd(long)
        let a = TextLayout.middleTruncate(nfd, maxWidth: 120, advance: Self.advance)
        let b = TextLayout.middleTruncate(long, maxWidth: 120, advance: Self.advance)
        #expect(Array(a.unicodeScalars) == Array(b.unicodeScalars))
    }

    @Test("Extensions that do not fit, dot files and tiny widths")
    func edgeCases() {
        // The ".pdf" tail (22) plus one head char (6) exceeds the 20-px budget: balanced instead.
        let r = TextLayout.middleTruncate("abcdefgh.pdf", maxWidth: 30, advance: Self.advance)
        #expect(r == "ab…f")
        #expect(width(r) <= 30)
        // A leading dot is not an extension.
        let dot = TextLayout.middleTruncate(".zshrc-backup-copy", maxWidth: 46, advance: Self.advance)
        #expect(dot == ".zs…opy")
        // Only the ellipsis fits / not even the ellipsis.
        #expect(TextLayout.middleTruncate("abcdef", maxWidth: 12, advance: Self.advance) == "…")
        #expect(TextLayout.middleTruncate("abcdef", maxWidth: 9, advance: Self.advance) == "")
        // Custom ellipsis.
        #expect(TextLayout.middleTruncate("abcdefghij", maxWidth: 40, advance: Self.advance, ellipsis: "..")
                == "abc..ij")
    }

    @Test("Only a short, space-free final suffix counts as an extension (M1 review F1)")
    func derivedExtension() {
        // Dots inside ordinary names (dates, versions) must not seed the tail.
        for name in ["Meeting notes 10.14 with the design team and more", "Project v2.Final draft of everything we did"] {
            let r = TextLayout.middleTruncate(name, maxWidth: 200, advance: Self.advance)
            let head = r.prefix { $0 != "…" }, tail = r.drop { $0 != "…" }.dropFirst()
            #expect(head.count >= 15 && abs(width(String(head)) - width(String(tail))) <= 10, "\(r)")
            #expect(width(r) <= 200)
            #expect(r == TextLayout.middleTruncate(name, maxWidth: 200, advance: Self.advance, extension: ""))
        }
        // Real extensions still stay whole; only the last suffix counts.
        let shot = TextLayout.middleTruncate("Screenshot 2026-10-14 at 9.41.03 AM.png", maxWidth: 100, advance: Self.advance)
        #expect(shot.hasSuffix(" AM.png") && shot.contains("…"), "\(shot)")
        let gz = TextLayout.middleTruncate("archive of the old backups.tar.gz", maxWidth: 80, advance: Self.advance)
        #expect(gz.hasSuffix(".gz"), "\(gz)")
        // More than 8 characters after the dot is not an extension.
        let long = "abcdefghijklmnop.abcdefghi"
        #expect(TextLayout.middleTruncate(long, maxWidth: 70, advance: Self.advance)
                == TextLayout.middleTruncate(long, maxWidth: 70, advance: Self.advance, extension: ""))
        #expect(TextLayout.middleTruncate("abcdefghijklmnop.abcdefgh", maxWidth: 70, advance: Self.advance)
                .hasSuffix(".abcdefgh"))
    }

    @Test("The caller can pass the extension, or none for folders (M1 review F1)")
    func explicitExtension() {
        let name = "Quarterly planning notes final v2.key"
        // A folder with dots: no extension, balanced.
        let folder = TextLayout.middleTruncate("Photos 2026.10.14 trip to the coast", maxWidth: 90, advance: Self.advance,
                                               extension: "")
        #expect(folder == "Photos …e coast")
        // The file model's extension wins over the heuristic, e.g. a long one.
        let pkg = "Some project archive.xcarchive2"
        let kept = TextLayout.middleTruncate(pkg, maxWidth: 100, advance: Self.advance, extension: "xcarchive2")
        #expect(kept.hasSuffix(".xcarchive2") && kept.hasPrefix("S"), "\(kept)")
        // An extension the name does not end with is ignored; a leading dot and NFD are accepted.
        #expect(TextLayout.middleTruncate(name, maxWidth: 90, advance: Self.advance, extension: "pdf")
                == TextLayout.middleTruncate(name, maxWidth: 90, advance: Self.advance, extension: ""))
        #expect(TextLayout.middleTruncate(name, maxWidth: 90, advance: Self.advance, extension: ".key")
                == TextLayout.middleTruncate(name, maxWidth: 90, advance: Self.advance, extension: "key"))
        let hangul = "보고서 최종 최최종 정말 마지막.한글"
        let r = TextLayout.middleTruncate(TestSupport.nfd(hangul), maxWidth: 60, advance: Self.advance,
                                          extension: TestSupport.nfd("한글"))
        #expect(r.hasSuffix(".한글"), "\(r)")
        // wrap passes the extension through to its last line.
        let backup = "Holiday photos from the coast.backup"
        #expect(TextLayout.wrap(backup, maxWidth: 70, maxLines: 2, advance: Self.advance) == ["Holiday", "pho….backup"])
        #expect(TextLayout.wrap(backup, maxWidth: 70, maxLines: 2, advance: Self.advance, extension: "")
                == ["Holiday", "photo…ackup"])
    }

    @Test("Wrap: breaks at spaces, last line middle-truncated")
    func wrapReport() {
        #expect(TextLayout.wrap(reportNFC, maxWidth: 40, maxLines: 2, advance: Self.advance) == ["보고서", "f….pdf"])
        #expect(TextLayout.wrap(reportNFC, maxWidth: 60, maxLines: 2, advance: Self.advance) == ["보고서", "final.pdf"])
        #expect(TextLayout.wrap(reportNFC, maxWidth: 200, maxLines: 2, advance: Self.advance) == [reportNFC])
        // NFD input wraps exactly like NFC.
        let a = TextLayout.wrap(reportNFD, maxWidth: 40, maxLines: 2, advance: Self.advance)
        #expect(a.map { Array($0.unicodeScalars) } == [Array("보고서".unicodeScalars), Array("f….pdf".unicodeScalars)])
    }

    @Test("Wrap: Hangul runs break anywhere")
    func wrapHangul() {
        let s = "가나다라마바사아자차"
        #expect(TextLayout.wrap(s, maxWidth: 35, maxLines: 5, advance: Self.advance) == ["가나다", "라마바", "사아자", "차"])
        // Mixed: a Latin word stays whole, Hangul splits next to it.
        #expect(TextLayout.wrap("abc가나다라", maxWidth: 40, maxLines: 3, advance: Self.advance) == ["abc가나", "다라"])
    }

    @Test("Wrap: words, long unbreakable runs, limits")
    func wrapLatin() {
        #expect(TextLayout.wrap("hello world foo", maxWidth: 40, maxLines: 3, advance: Self.advance)
                == ["hello", "world", "foo"])
        #expect(TextLayout.wrap("hello world foo", maxWidth: 70, maxLines: 3, advance: Self.advance)
                == ["hello world", "foo"])
        #expect(TextLayout.wrap("abcdefghij", maxWidth: 25, maxLines: 3, advance: Self.advance)
                == ["abcd", "efgh", "ij"])
        #expect(TextLayout.wrap("a  b", maxWidth: 6, maxLines: 3, advance: Self.advance) == ["a", "b"])
        // A leading space must not cost a line (M1 review F12).
        #expect(TextLayout.wrap(" 나 b", maxWidth: 12, maxLines: 2, advance: Self.advance) == ["나", "b"])
        #expect(TextLayout.wrap("   abcdef", maxWidth: 12, maxLines: 3, advance: Self.advance) == ["ab", "cd", "ef"])
        #expect(TextLayout.wrap(" ab", maxWidth: 40, maxLines: 2, advance: Self.advance) == [" ab"])
        #expect(TextLayout.wrap("", maxWidth: 40, maxLines: 2, advance: Self.advance).isEmpty)
        #expect(TextLayout.wrap("abc", maxWidth: 40, maxLines: 0, advance: Self.advance).isEmpty)

        let long = "Quarterly planning notes for the whole team final v2.key"
        let one = TextLayout.wrap(long, maxWidth: 100, maxLines: 1, advance: Self.advance)
        #expect(one == [TextLayout.middleTruncate(long, maxWidth: 100, advance: Self.advance)])
        let two = TextLayout.wrap(long, maxWidth: 100, maxLines: 2, advance: Self.advance)
        #expect(two.count == 2)
        #expect(two[1].hasSuffix(".key") && two[1].contains("…"))
        for line in two { #expect(width(line) <= 100) }
    }

    @Test("CJK detection")
    func cjk() {
        for c: Character in ["가", "힣", "ㄱ", "あ", "カ", "漢", "。", "Ａ"] { #expect(TextLayout.isCJK(c), "\(c)") }
        for c: Character in ["a", "Z", "1", " ", ".", "é", "Ж", "😀"] { #expect(!TextLayout.isCJK(c), "\(c)") }
    }
}
