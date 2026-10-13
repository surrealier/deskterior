import Testing
@testable import DeskCore

@Suite struct SpriteTests {
    private let key: [Character: Ink] = [".": .clear, "k": .neutral0, "b": .blue3, "r": .red3]

    @Test func parsesIndentedLiteralWithBlankLines() throws {
        let s = try IndexedSprite(parsing: """

                .k.
            \tkbr

                  .k.

            """, key: key)
        #expect(s.w == 3)
        #expect(s.h == 3)
        #expect(s.size == ArtSize(3, 3))
        #expect(s.inks == [.clear, .neutral0, .clear, .neutral0, .blue3, .red3, .clear, .neutral0, .clear])
        #expect(s[2, 1] == .red3)
    }

    @Test func parsesCRLFLineEndings() throws {
        let s = try IndexedSprite(parsing: "kb\r\nrk\r\n", key: key)
        #expect(s.inks == [.neutral0, .blue3, .red3, .neutral0])
    }

    @Test func raggedRowIsRejected() {
        #expect(throws: SpriteError.ragged(row: 1, expected: 3, got: 2)) {
            try IndexedSprite(parsing: """
                ...
                ..
                ...
                """, key: key)
        }
        #expect(throws: SpriteError.ragged(row: 2, expected: 2, got: 4)) {
            try IndexedSprite(parsing: "..\n..\n....", key: key)
        }
    }

    @Test func unknownCharacterIsRejectedWithPosition() {
        #expect(throws: SpriteError.unknownCharacter("?", row: 1, col: 2)) {
            try IndexedSprite(parsing: """
                ....
                ..?.
                """, key: key)
        }
        // Interior spaces are characters, not transparency.
        #expect(throws: SpriteError.unknownCharacter(" ", row: 0, col: 1)) {
            try IndexedSprite(parsing: "k k", key: key)
        }
    }

    @Test func emptyArtIsRejected() {
        #expect(throws: SpriteError.empty) { try IndexedSprite(parsing: "", key: key) }
        #expect(throws: SpriteError.empty) { try IndexedSprite(parsing: "   \n\t\n  ", key: key) }
    }

    @Test func errorsDescribeThemselves() {
        #expect(SpriteError.ragged(row: 1, expected: 3, got: 2).description.contains("row 1"))
        #expect(SpriteError.unknownCharacter("?", row: 0, col: 4).description.contains("col 4"))
    }

    @Test func rendersPixelByPixel() {
        let s = IndexedSprite("""
            .k
            br
            """, key)
        let buf = s.render()
        #expect(buf.width == 2 && buf.height == 2)
        #expect(buf[0, 0] == RGBA8.clear)
        #expect(buf[1, 0] == RGBA8(hex: 0x090a14))
        #expect(buf[0, 1] == RGBA8(hex: 0x4f8fba))
        #expect(buf[1, 1] == RGBA8(hex: 0xa53030))
    }

    @Test func renderWithRemapSwapsPalette() {
        let s = IndexedSprite("kbb.", key)
        let buf = s.render(remap: [.blue3: .green3, .neutral0: .clear])
        #expect(buf.pixels == [.clear, Ink.green3.color, Ink.green3.color, .clear])
        #expect(s.render(remap: [:]) == s.render())
        #expect(s.remapped([.blue3: .green3]).inks == [.neutral0, .green3, .green3, .clear])
    }

    @Test func flipsMirrorRowsAndColumns() {
        let s = IndexedSprite("""
            kb.
            ..r
            """, key)
        #expect(s.flippedHorizontally() == IndexedSprite("""
            .bk
            r..
            """, key))
        #expect(s.flippedVertically() == IndexedSprite("""
            ..r
            kb.
            """, key))
        #expect(s.flippedHorizontally().flippedHorizontally() == s)
        #expect(s.flippedHorizontally().render() == s.render().flippedHorizontally())
    }

    @Test func framesSplitOnSeparatorLines() throws {
        let frames = IndexedSprite.frames("""
            .k.
            kbk
              ---
            .r.
            rbr
            ---

            kk
            """, key: key)
        #expect(frames.count == 3)
        #expect(frames[0].inks == [.clear, .neutral0, .clear, .neutral0, .blue3, .neutral0])
        #expect(frames[1].inks == [.clear, .red3, .clear, .red3, .blue3, .red3])
        #expect(frames[2].size == ArtSize(2, 1))
        #expect(try IndexedSprite.parsingFrames("kb\n---\nbk", key: key).map(\.inks) == [[.neutral0, .blue3], [.blue3, .neutral0]])
    }

    @Test func separatorsAroundTheStripAreIgnored() throws {
        // M1 review F13: a `---` before the first frame or after the last one is not an empty frame.
        let one = try IndexedSprite.parsingFrames("---\nkk\nkk\n---", key: key)
        #expect(one.map(\.inks) == [[.neutral0, .neutral0, .neutral0, .neutral0]])
        let framed = IndexedSprite.frames("""
            ---
            kb
            ---
            bk
            ---

            """, key: key)
        #expect(framed.map(\.inks) == [[.neutral0, .blue3], [.blue3, .neutral0]])
        #expect(throws: SpriteError.empty) { try IndexedSprite.parsingFrames("---\n---", key: key) }
        #expect(throws: SpriteError.empty) { try IndexedSprite.parsingFrames("", key: key) }
    }

    @Test func emptyOrBadFramesThrow() {
        #expect(throws: SpriteError.empty) { try IndexedSprite.parsingFrames("kb\n---\n---\nbk", key: key) }
        #expect(throws: SpriteError.ragged(row: 1, expected: 2, got: 1)) {
            try IndexedSprite.parsingFrames("kb\n---\nkb\nk", key: key)
        }
    }

    @Test func standardKeyCoversEveryInkWithKeyboardRuns() {
        let k = SpriteKey.standard
        #expect(Set(k.values).count == Apollo.count + 1)  // all 46 inks plus clear
        #expect(k["."] == .clear)
        #expect(k["k"] == .neutral0)
        #expect(!k.keys.contains { $0.isWhitespace })
        let runs: [(String, Apollo.Ramp)] = [
            ("qwerty", .blue), ("asdfgh", .green), ("zxcvbn", .oak),
            ("QWERTY", .purple), ("ASDFGH", .red), ("ZXCVBN", .walnut), ("0123456789", .neutral),
        ]
        for (chars, ramp) in runs {
            #expect(chars.compactMap { k[$0] } == ramp.indices.map { Ink(palette: $0) }, "run \(chars)")
        }
        #expect(k["b"] == Role.desk)
        #expect(k["N"] == Role.lampGlow)
        for free in "uiopjlmUIOPJKLM" { #expect(k[free] == nil, "\(free) is reserved for custom keys") }
    }

    @Test func standardKeyIsTheDefault() {
        let s = IndexedSprite("""
            k0.9
            qyQN
            """)
        #expect(s.inks == [.neutral0, .neutral0, .clear, .neutral9, .blue0, .blue5, .purple0, .walnut5])
    }

    @Test func keyHelpersMergeAndBindRamps() {
        let oak = SpriteKey.ramp(.oak, "dml", from: 2)
        #expect(oak == ["d": .oak2, "m": .oak3, "l": .oak4])
        #expect(SpriteKey.ramp(.neutral, "ab") == ["a": .neutral0, "b": .neutral1])
        let merged = SpriteKey.extending(["k": .red0, "o": .blue2])
        #expect(merged["k"] == .red0)
        #expect(merged["o"] == .blue2)
        #expect(merged["q"] == .blue0)
        #expect(merged.count == SpriteKey.standard.count + 1)
    }

    @Test func asciiRoundTripsThroughTheKey() throws {
        let s = IndexedSprite("""
            .kkk.
            kvbnk
            kZTak
            .kkk.
            """)
        let dump = s.ascii()
        // neutral0 has two characters ('0' and 'k'); the smaller one ('0') is printed.
        #expect(dump.split(separator: "\n").first == ".000.")
        #expect(try IndexedSprite(parsing: dump, key: SpriteKey.standard) == s)
        #expect(s.description.hasPrefix("IndexedSprite 5x4"))
        #expect(IndexedSprite("kb", key).ascii(key: ["k": .neutral0]) == "k?")
    }

    @Test func readsBackExactBuffers() {
        let s = IndexedSprite("k.\nbr", key)
        #expect(IndexedSprite(exactly: s.render()) == s)
        var off = s.render()
        off[1, 0] = RGBA8(1, 2, 3)
        #expect(IndexedSprite(exactly: off) == nil)
        off[1, 0] = RGBA8(9, 9, 9, 0)  // transparent but not `.clear`
        #expect(IndexedSprite(exactly: off) == nil)
    }
}
