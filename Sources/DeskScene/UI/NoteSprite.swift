import DeskCore
import DeskPixels
import Foundation

/// A sticky note as the partition draws it (Erratum 31): `PartitionArt.notePaper` (its colour, the date flag, tape or
/// a pushpin by id) with its first line of text in Galmuri9 (neutral2) clipped to whole glyphs in the 26-px text band,
/// and a scribbled rule under it for each further line (two at most). Text is NFC, so Korean draws precomposed.
/// Images are cached by what they show, so a note redraws only when its look changes.
enum NoteSprite {
    /// What a note's picture depends on.
    struct Look: Hashable {
        /// The first line as drawn (already clipped to the band).
        var line: String
        /// Rules for the lines after it (0…2).
        var scribbles: Int
        var colour: NoteColour
        var dated: Bool
        var pinned: Bool
    }

    static let textInk = Ink.neutral2
    static let scribbleInk = Ink.neutral5
    /// The text band inside the note (`PartitionLayout.textBand` less the note's origin).
    static var band: ArtRect {
        PartitionLayout.textBand(at: .zero)
    }
    /// The rows the scribbles take, under the band, and how long each is.
    static let scribbleRows = [18, 21]
    static let scribbleLengths = [22, 15]

    // MARK: Looks

    static func look(_ note: StickyNote, font: PixelFont?) -> Look {
        let lines = textLines(note.text)
        let first = lines.first.map { clipped($0, width: band.w, font: font) } ?? ""
        return Look(line: first, scribbles: min(scribbleRows.count, max(0, lines.count - 1)), colour: note.colour,
                    dated: note.day != nil, pinned: note.id.number % 2 == 1)
    }

    /// The note's non-empty lines (trimmed), NFC.
    static func textLines(_ text: String) -> [String] {
        TextLayout.nfc(text).split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `line` cut after its last whole glyph that fits in `width` px.
    static func clipped(_ line: String, width: Int, font: PixelFont?) -> String {
        var out = "", w = 0
        for c in TextLayout.nfc(line) {
            let a = font?.advance(of: c) ?? 6
            guard w + a <= width else { break }
            out.append(c)
            w += a
        }
        return out
    }

    // MARK: Images

    static func image(_ note: StickyNote, font: PixelFont?) -> PixelBuffer {
        image(look(note, font: font), font: font)
    }

    static func image(_ look: Look, font: PixelFont?) -> PixelBuffer {
        if let cached = cache[look] { return cached }
        var c = PixelCanvas(PartitionArt.notePaper(look.colour, dated: look.dated, pinned: look.pinned).image)
        if let font, !look.line.isEmpty {
            c.blit(textLine(look.line, ink: textInk, height: band.h, font: font), at: band.origin)
        }
        for i in 0..<look.scribbles {
            c.hline(x: band.x, y: scribbleRows[i], length: scribbleLengths[i], scribbleInk)
        }
        if cache.count >= maxCached { cache.removeAll() }
        cache[look] = c.buffer
        return c.buffer
    }

    /// One line of Galmuri9 cropped to its ink rows (Galmuri9's are 12, the band's height) and at most `height`.
    static func textLine(_ s: String, ink: Ink, height: Int, font: PixelFont) -> PixelBuffer {
        let line = PixelText.line(s, ink, font: font)
        return line.height <= height ? line : line.cropped(to: ArtRect(0, 0, line.width, height))
    }

    /// The pad's overlay (Erratum 31): today's first line on the page at (2, 19), clipped to whole glyphs in 34 px.
    static func padLine(_ text: String, font: PixelFont?) -> PixelBuffer? {
        guard let font, let first = textLines(text).first else { return nil }
        let line = clipped(first, width: padBand.w, font: font)
        guard !line.isEmpty else { return nil }
        return textLine(line, ink: textInk, height: padBand.h, font: font)
    }

    /// Where the pad's line sits on the pad sprite.
    static let padBand = ArtRect(2, 19, 34, 12)

    /// A note 1 px bigger on every side (nearest neighbour), for the pop a new note makes.
    static func grown(_ b: PixelBuffer) -> PixelBuffer {
        var out = PixelBuffer(width: b.width + 2, height: b.height + 2)
        for y in 0..<out.height {
            let sy = min(b.height - 1, y * b.height / out.height)
            for x in 0..<out.width {
                out[x, y] = b.pixel(min(b.width - 1, x * b.width / out.width), sy)
            }
        }
        return out
    }

    private static var cache: [Look: PixelBuffer] = [:]
    private static let maxCached = 96
}
