/// Why an ASCII sprite failed to parse. Rows and columns are 0-based and count only the art itself:
/// blank lines are skipped and each row's surrounding whitespace is trimmed before counting.
public enum SpriteError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The art has no non-blank rows.
    case empty
    /// Row `row` is `got` characters wide, but the first row is `expected` wide.
    case ragged(row: Int, expected: Int, got: Int)
    /// A character that is not in the key (interior spaces included).
    case unknownCharacter(Character, row: Int, col: Int)

    public var description: String {
        switch self {
        case .empty:
            "sprite art has no rows"
        case let .ragged(row, expected, got):
            "ragged sprite: row \(row) is \(got) wide, expected \(expected)"
        case let .unknownCharacter(c, row, col):
            "character \(String(reflecting: String(c))) at row \(row), col \(col) is not in the sprite key"
        }
    }
}

/// A sprite authored as code: a rectangular grid of `Ink`s parsed from ASCII art plus a key
/// (DESIGN §1, R2 §2.1). Row 0 is the top row.
///
/// ```swift
/// static let cup = IndexedSprite("""
///     .kkkk.
///     kvbbnk
///     kvbbbk
///     .kkkk.
///     """)                                  // SpriteKey.standard: k outline, v/b/n oak 3/4/5
/// ```
///
/// Parsing rules: lines are split on any newline; each line is trimmed of surrounding whitespace and
/// blank lines are dropped, so art can be indented freely inside a Swift multi-line literal. Spaces
/// therefore never mean "transparent" — use `.` (or any character the key maps to `.clear`); a space
/// inside a row is an unknown character unless the key maps it.
public struct IndexedSprite: Hashable, Sendable, CustomStringConvertible {
    public let w: Int
    public let h: Int
    /// `w * h` inks, row-major from the top-left.
    public let inks: [Ink]

    public init(w: Int, h: Int, inks: [Ink]) {
        precondition(w >= 0 && h >= 0 && inks.count == w * h, "IndexedSprite: \(inks.count) inks for \(w)x\(h)")
        self.w = w
        self.h = h
        self.inks = inks
    }

    /// Parses ASCII art with `key`; see the type documentation for the rules.
    public init(parsing art: String, key: [Character: Ink]) throws(SpriteError) {
        try self.init(rows: Self.lines(of: art).filter { !$0.isEmpty }, key: key)
    }

    /// Parses static art and traps with a descriptive message (pointing at the call site) when the art
    /// is malformed. Use for art literals compiled into the app; `init(parsing:key:)` for anything else.
    public init(
        _ art: String,
        _ key: [Character: Ink] = SpriteKey.standard,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        do {
            self = try IndexedSprite(parsing: art, key: key)
        } catch {
            preconditionFailure("IndexedSprite: \(error)", file: file, line: line)
        }
    }

    private init(rows: [Substring], key: [Character: Ink]) throws(SpriteError) {
        guard let first = rows.first else { throw .empty }
        let width = first.count
        var inks: [Ink] = []
        inks.reserveCapacity(width * rows.count)
        for (r, row) in rows.enumerated() {
            let count = row.count
            if count != width { throw .ragged(row: r, expected: width, got: count) }
            for (c, ch) in row.enumerated() {
                guard let ink = key[ch] else { throw .unknownCharacter(ch, row: r, col: c) }
                inks.append(ink)
            }
        }
        self.init(w: width, h: rows.count, inks: inks)
    }

    /// Parses an animation strip: frames are separated by lines that are exactly `---` (after trimming).
    /// Separators before the first frame or after the last one are ignored; every other frame must be
    /// non-empty. Frames may differ in size. Traps on malformed art, naming the frame.
    public static func frames(
        _ art: String,
        key: [Character: Ink] = SpriteKey.standard,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> [IndexedSprite] {
        var out: [IndexedSprite] = []
        for (i, chunk) in frameChunks(of: art).enumerated() {
            do {
                out.append(try IndexedSprite(rows: chunk, key: key))
            } catch {
                preconditionFailure("IndexedSprite frame \(i): \(error)", file: file, line: line)
            }
        }
        return out
    }

    /// Throwing form of `frames(_:key:)`. Row numbers in errors are relative to the failing frame.
    public static func parsingFrames(_ art: String, key: [Character: Ink]) throws(SpriteError) -> [IndexedSprite] {
        var out: [IndexedSprite] = []
        for chunk in frameChunks(of: art) {
            out.append(try IndexedSprite(rows: chunk, key: key))
        }
        return out
    }

    public var size: ArtSize { ArtSize(w, h) }

    /// Ink at `(x, y)` (traps when out of bounds).
    public subscript(x: Int, y: Int) -> Ink {
        precondition(x >= 0 && y >= 0 && x < w && y < h, "IndexedSprite read out of bounds (\(x),\(y)) in \(w)x\(h)")
        return inks[y * w + x]
    }

    /// The sprite as RGBA (Apollo colours; `.clear` stays fully transparent).
    public func render() -> PixelBuffer {
        PixelBuffer(width: w, height: h, pixels: inks.map(\.color))
    }

    /// Renders with a palette swap: each ink found in `remap` is drawn as its mapped ink (mapping to
    /// `.clear` hides it). Inks not in `remap` are unchanged.
    public func render(remap: [Ink: Ink]) -> PixelBuffer {
        guard !remap.isEmpty else { return render() }
        let table = Self.colorTable(remap)
        return PixelBuffer(width: w, height: h, pixels: inks.map { table[Int($0.raw)] })
    }

    /// The same sprite with its inks swapped through `remap`.
    public func remapped(_ remap: [Ink: Ink]) -> IndexedSprite {
        IndexedSprite(w: w, h: h, inks: inks.map { remap[$0] ?? $0 })
    }

    /// Mirrored left ↔ right.
    public func flippedHorizontally() -> IndexedSprite {
        var out: [Ink] = []
        out.reserveCapacity(inks.count)
        for y in 0..<h {
            let row = y * w
            for x in stride(from: w - 1, through: 0, by: -1) { out.append(inks[row + x]) }
        }
        return IndexedSprite(w: w, h: h, inks: out)
    }

    /// Mirrored top ↔ bottom.
    public func flippedVertically() -> IndexedSprite {
        var out: [Ink] = []
        out.reserveCapacity(inks.count)
        for y in stride(from: h - 1, through: 0, by: -1) { out.append(contentsOf: inks[(y * w)..<(y * w + w)]) }
        return IndexedSprite(w: w, h: h, inks: out)
    }

    /// Reads a buffer back into inks; nil if any pixel is neither `.clear` nor an opaque Apollo colour.
    /// Handy for comparing procedural drawing against ASCII art in tests.
    public init?(exactly buffer: PixelBuffer) {
        var inks: [Ink] = []
        inks.reserveCapacity(buffer.pixels.count)
        for c in buffer.pixels {
            if c == .clear {
                inks.append(.clear)
            } else if let i = Apollo.index(of: c) {
                inks.append(Ink(palette: i))
            } else {
                return nil
            }
        }
        self.init(w: buffer.width, h: buffer.height, inks: inks)
    }

    /// The sprite as ASCII art using `key` in reverse (the smallest character wins when several map to
    /// the same ink; inks missing from the key print as `?`). Parsing the result with the same key
    /// reproduces the sprite whenever every ink is mapped.
    public func ascii(key: [Character: Ink] = SpriteKey.standard) -> String {
        var reverse: [Ink: Character] = [:]
        for (c, ink) in key.sorted(by: { $0.key < $1.key }) where reverse[ink] == nil { reverse[ink] = c }
        var s = ""
        s.reserveCapacity((w + 1) * h)
        for y in 0..<h {
            if y > 0 { s.append("\n") }
            for x in 0..<w { s.append(reverse[inks[y * w + x]] ?? "?") }
        }
        return s
    }

    public var description: String { "IndexedSprite \(w)x\(h)\n\(ascii())" }

    // MARK: - Parsing helpers

    /// All lines (blank ones included) with surrounding whitespace trimmed.
    private static func lines(of art: String) -> [Substring] {
        art.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(trimmed)
    }

    /// Frames' rows, split on `---` lines. Empty chunks at either end are dropped (an all-separator strip
    /// keeps one, so it still fails as `.empty`).
    private static func frameChunks(of art: String) -> [[Substring]] {
        var chunks: [[Substring]] = [[]]
        for line in lines(of: art) {
            if line == "---" {
                chunks.append([])
            } else if !line.isEmpty {
                chunks[chunks.count - 1].append(line)
            }
        }
        while chunks.count > 1, chunks[0].isEmpty { chunks.removeFirst() }
        while chunks.count > 1, chunks[chunks.count - 1].isEmpty { chunks.removeLast() }
        return chunks
    }

    private static func trimmed(_ s: Substring) -> Substring {
        var t = s
        while let c = t.first, c.isWhitespace { t = t.dropFirst() }
        while let c = t.last, c.isWhitespace { t = t.dropLast() }
        return t
    }

    /// Colour per `Ink.raw` (0…46) after applying `remap`.
    private static func colorTable(_ remap: [Ink: Ink]) -> [RGBA8] {
        (0...Apollo.count).map { raw in
            let ink = Ink(raw: UInt8(raw))
            return (remap[ink] ?? ink).color
        }
    }
}

/// The shared sprite key: one character for every Apollo colour, so most sprites need no custom key.
///
/// Each colour ramp is a six-key run on a keyboard row, **dark → light from left to right**. Rows pick
/// the ramp (sky on top, plants in the middle, wood at the bottom) and Shift picks the row's partner ramp.
///
/// | Keys (dark → light) | Inks | Mnemonic |
/// |---|---|---|
/// | `q w e r t y` | `blue0`…`blue5` | top row: sky |
/// | `a s d f g h` | `green0`…`green5` | home row: grass and plants |
/// | `z x c v b n` | `oak0`…`oak5` | bottom row: wood (the desk) |
/// | `Q W E R T Y` | `purple0`…`purple5` | Shift + sky |
/// | `A S D F G H` | `red0`…`red5` | Shift + grass (its complement) |
/// | `Z X C V B N` | `walnut0`…`walnut5` | Shift + wood (darker wood, lamp glow) |
/// | `0 1 2 … 9` | `neutral0`…`neutral9` | grey level, same digit as the ink name |
/// | `k` | `neutral0` | outline ("key" black, as in CMYK) |
/// | `.` | `.clear` | transparent |
///
/// Free for per-sprite keys: `u i o p j l m U I O P J K L M` and punctuation (never space). Merge a
/// custom key over this one with `SpriteKey.extending(_:)`; custom entries win.
public enum SpriteKey {
    public static let standard: [Character: Ink] = {
        var key: [Character: Ink] = [".": .clear, "k": .neutral0]
        let runs: [(String, Apollo.Ramp)] = [
            ("qwerty", .blue), ("asdfgh", .green), ("zxcvbn", .oak),
            ("QWERTY", .purple), ("ASDFGH", .red), ("ZXCVBN", .walnut),
            ("0123456789", .neutral),
        ]
        for (chars, ramp) in runs {
            for (i, c) in chars.enumerated() { key[c] = Ink(palette: ramp.indices.lowerBound + i) }
        }
        return key
    }()

    /// `standard` with `overrides` merged on top (override entries win).
    public static func extending(_ overrides: [Character: Ink]) -> [Character: Ink] {
        standard.merging(overrides) { _, custom in custom }
    }

    /// Binds `chars` (dark → light) to consecutive steps of `ramp`, starting at step `from`.
    /// `SpriteKey.ramp(.oak, "dml", from: 2)` maps `d` → `oak2`, `m` → `oak3`, `l` → `oak4`.
    public static func ramp(_ ramp: Apollo.Ramp, _ chars: String, from step: Int = 0) -> [Character: Ink] {
        let steps = ramp.indices.count
        precondition(step >= 0 && step + chars.count <= steps, "SpriteKey.ramp: \(chars.count) keys from step \(step) overflow \(ramp) (\(steps) steps)")
        var key: [Character: Ink] = [:]
        for (i, c) in chars.enumerated() { key[c] = Ink(palette: ramp.indices.lowerBound + step + i) }
        return key
    }
}
