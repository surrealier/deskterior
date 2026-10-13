/// A hand-pixelled 5-px-tall font for badges, the OSD and tiny labels (DESIGN §2: "+N" badges, INPUT,
/// calendar months). Digits are 3 px wide; letters are 3 px except the narrow `I` and the wide `M`, `N`, `W`.
/// Glyphs are drawn in one ink on transparent; advance = glyph width + 1.
public enum Digits {
    public static let height = 5

    /// `#` = ink. Unknown characters render as a space.
    static let glyphs: [Character: [String]] = [
        "0": ["###", "#.#", "#.#", "#.#", "###"],
        "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["##.", "..#", ".#.", "#..", "###"],
        "3": ["##.", "..#", ".#.", "..#", "##."],
        "4": ["#.#", "#.#", "###", "..#", "..#"],
        "5": ["###", "#..", "##.", "..#", "##."],
        "6": [".##", "#..", "###", "#.#", "###"],
        "7": ["###", "..#", ".#.", ".#.", ".#."],
        "8": ["###", "#.#", "###", "#.#", "###"],
        "9": ["###", "#.#", "###", "..#", "##."],
        "+": ["...", ".#.", "###", ".#.", "..."],
        "-": ["...", "...", "###", "...", "..."],
        ":": [".", "#", ".", "#", "."],
        "·": [".", ".", "#", ".", "."],
        " ": ["..", "..", "..", "..", ".."],
        "A": [".#.", "#.#", "###", "#.#", "#.#"],
        "B": ["##.", "#.#", "##.", "#.#", "##."],
        "C": [".##", "#..", "#..", "#..", ".##"],
        "D": ["##.", "#.#", "#.#", "#.#", "##."],
        "E": ["###", "#..", "##.", "#..", "###"],
        "F": ["###", "#..", "##.", "#..", "#.."],
        "G": [".##", "#..", "#.#", "#.#", ".##"],
        "H": ["#.#", "#.#", "###", "#.#", "#.#"],
        "I": ["#", "#", "#", "#", "#"],
        "J": ["..#", "..#", "..#", "#.#", ".#."],
        "K": ["#.#", "#.#", "##.", "#.#", "#.#"],
        "L": ["#..", "#..", "#..", "#..", "###"],
        "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#"],
        "N": ["#..#", "##.#", "#.##", "#..#", "#..#"],
        "O": [".#.", "#.#", "#.#", "#.#", ".#."],
        "P": ["##.", "#.#", "##.", "#..", "#.."],
        "R": ["##.", "#.#", "##.", "#.#", "#.#"],
        "S": [".##", "#..", ".#.", "..#", "##."],
        "T": ["###", ".#.", ".#.", ".#.", ".#."],
        "U": ["#.#", "#.#", "#.#", "#.#", "###"],
        "V": ["#.#", "#.#", "#.#", "#.#", ".#."],
        "W": ["#...#", "#...#", "#.#.#", "##.##", "#...#"],
        "Y": ["#.#", "#.#", ".#.", ".#.", ".#."],
    ]

    /// Width of one glyph (0 for none).
    public static func width(of c: Character) -> Int {
        (glyphs[c] ?? glyphs[" "]!)[0].count
    }

    /// Width of a string: glyph widths plus 1-px gaps.
    public static func measure(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        return s.reduce(0) { $0 + width(of: $1) + 1 } - 1
    }

    /// Draws `s` with its top-left at `origin`.
    public static func draw(_ s: String, at origin: ArtPoint, _ ink: Ink, into canvas: inout PixelCanvas) {
        var x = origin.x
        for c in s {
            let rows = glyphs[c] ?? glyphs[" "]!
            for (dy, row) in rows.enumerated() {
                for (dx, ch) in row.enumerated() where ch == "#" {
                    canvas.plot(x + dx, origin.y + dy, ink)
                }
            }
            x += rows[0].count + 1
        }
    }

    /// `s` rendered on transparent.
    public static func render(_ s: String, _ ink: Ink) -> PixelBuffer {
        var c = PixelCanvas(width: max(1, measure(s)), height: height)
        draw(s, at: .zero, ink, into: &c)
        return c.buffer
    }

    /// A count badge ("+N" style): `text` in light ink on a rounded pill with a dark rim.
    public static func badge(_ text: String, fill: Ink = .red3, ink: Ink = .neutral9, rim: Ink = .red1) -> PixelBuffer {
        let w = measure(text) + 6, h = height + 4
        var c = PixelCanvas(width: w, height: h)
        c.roundedRectFill(c.bounds, radius: 2, rim)
        c.roundedRectFill(c.bounds.insetBy(1, 1), radius: 1, fill)
        c.hline(x: 2, y: 1, length: w - 4, fill.lighter())
        draw(text, at: ArtPoint(3, 2), ink, into: &c)
        return c.buffer
    }
}
