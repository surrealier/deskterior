/// The Apollo palette by AdamCYounis (46 colours, https://lospec.com/palette-list/apollo), in Lospec's
/// canonical order. Every pixel Deskterior draws is one of these colours (or transparent).
public enum Apollo {
    /// Canonical order: 7 ramps, each dark → light.
    public static let hex: [UInt32] = [
        // blue (0–5)
        0x172038, 0x253a5e, 0x3c5e8b, 0x4f8fba, 0x73bed3, 0xa4dddb,
        // green (6–11)
        0x19332d, 0x25562e, 0x468232, 0x75a743, 0xa8ca58, 0xd0da91,
        // oak (12–17)
        0x4d2b32, 0x7a4841, 0xad7757, 0xc09473, 0xd7b594, 0xe7d5b3,
        // walnut / glow (18–23)
        0x341c27, 0x602c2c, 0x884b2b, 0xbe772b, 0xde9e41, 0xe8c170,
        // red (24–29)
        0x241527, 0x411d31, 0x752438, 0xa53030, 0xcf573c, 0xda863e,
        // purple (30–35)
        0x1e1d39, 0x402751, 0x7a367b, 0xa23e8c, 0xc65197, 0xdf84a5,
        // neutral (36–45)
        0x090a14, 0x10141f, 0x151d28, 0x202e37, 0x394a50, 0x577277, 0x819796, 0xa8b5b2, 0xc7cfcc, 0xebede9,
    ]

    /// `hex` as opaque colours; `colors[i]` is palette index `i`.
    public static let colors: [RGBA8] = hex.map { RGBA8(hex: $0) }

    public static let count = 46

    public enum Ramp: Int, CaseIterable, Sendable {
        case blue, green, oak, walnut, red, purple, neutral

        /// Palette indices of this ramp, dark → light.
        public var indices: Range<Int> {
            switch self {
            case .blue: 0..<6
            case .green: 6..<12
            case .oak: 12..<18
            case .walnut: 18..<24
            case .red: 24..<30
            case .purple: 30..<36
            case .neutral: 36..<46
            }
        }
    }

    /// The ramp a palette index belongs to.
    public static func ramp(of index: Int) -> Ramp {
        precondition(index >= 0 && index < count, "palette index out of range: \(index)")
        return Ramp.allCases.first { $0.indices.contains(index) }!
    }

    /// Palette index of an exact colour, or nil if `c` is not an opaque Apollo colour.
    public static func index(of c: RGBA8) -> Int? {
        guard c.a == 255 else { return nil }
        return indexByRGB[c.rgbHex]
    }

    private static let indexByRGB: [UInt32: Int] = {
        var d: [UInt32: Int] = [:]
        for (i, h) in hex.enumerated() { d[h] = i }
        return d
    }()
}

/// A sprite "ink": transparent, or one Apollo colour. Stored as `raw` = 0 (clear) or `paletteIndex + 1`,
/// so sprite grids can use 0 for transparency.
public struct Ink: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UInt8

    public init(raw: UInt8) {
        precondition(Int(raw) <= Apollo.count, "ink out of range: \(raw)")
        self.raw = raw
    }

    /// Ink for palette index `i` (0-based).
    public init(palette i: Int) {
        precondition(i >= 0 && i < Apollo.count, "palette index out of range: \(i)")
        self.raw = UInt8(i + 1)
    }

    public static let clear = Ink(raw: 0)

    public var isClear: Bool { raw == 0 }
    /// 0-based palette index, or nil for `.clear`.
    public var paletteIndex: Int? { raw == 0 ? nil : Int(raw) - 1 }
    public var color: RGBA8 { raw == 0 ? .clear : Apollo.colors[Int(raw) - 1] }

    public var description: String { raw == 0 ? "clear" : "ink\(Int(raw) - 1)" }

    // Named inks: ramp + step (0 = darkest).
    public static let blue0 = Ink(palette: 0), blue1 = Ink(palette: 1), blue2 = Ink(palette: 2)
    public static let blue3 = Ink(palette: 3), blue4 = Ink(palette: 4), blue5 = Ink(palette: 5)
    public static let green0 = Ink(palette: 6), green1 = Ink(palette: 7), green2 = Ink(palette: 8)
    public static let green3 = Ink(palette: 9), green4 = Ink(palette: 10), green5 = Ink(palette: 11)
    public static let oak0 = Ink(palette: 12), oak1 = Ink(palette: 13), oak2 = Ink(palette: 14)
    public static let oak3 = Ink(palette: 15), oak4 = Ink(palette: 16), oak5 = Ink(palette: 17)
    public static let walnut0 = Ink(palette: 18), walnut1 = Ink(palette: 19), walnut2 = Ink(palette: 20)
    public static let walnut3 = Ink(palette: 21), walnut4 = Ink(palette: 22), walnut5 = Ink(palette: 23)
    public static let red0 = Ink(palette: 24), red1 = Ink(palette: 25), red2 = Ink(palette: 26)
    public static let red3 = Ink(palette: 27), red4 = Ink(palette: 28), red5 = Ink(palette: 29)
    public static let purple0 = Ink(palette: 30), purple1 = Ink(palette: 31), purple2 = Ink(palette: 32)
    public static let purple3 = Ink(palette: 33), purple4 = Ink(palette: 34), purple5 = Ink(palette: 35)
    public static let neutral0 = Ink(palette: 36), neutral1 = Ink(palette: 37), neutral2 = Ink(palette: 38)
    public static let neutral3 = Ink(palette: 39), neutral4 = Ink(palette: 40), neutral5 = Ink(palette: 41)
    public static let neutral6 = Ink(palette: 42), neutral7 = Ink(palette: 43), neutral8 = Ink(palette: 44)
    public static let neutral9 = Ink(palette: 45)
}

/// Semantic colour roles (docs/DESIGN.md §1.4). Use these instead of raw inks in element code.
public enum Role {
    public static let desk = Ink.oak4            // d7b594
    public static let deskHighlight = Ink.oak5   // e7d5b3
    public static let deskEdge = Ink.oak3        // c09473
    public static let deskShadow = Ink.oak2      // ad7757
    public static let bezel = Ink.neutral2       // 151d28
    public static let bezelLight = Ink.neutral3  // 202e37
    public static let screenOff = Ink.neutral0   // 090a14
    public static let screenGlare = Ink.neutral4 // 394a50
    public static let feltMat = Ink.neutral4     // 394a50
    public static let feltMatLight = Ink.neutral5 // 577277
    public static let selection = Ink.blue3      // 4f8fba
    public static let ledOn = Ink.green3         // 75a743
    public static let ledAmber = Ink.walnut4     // de9e41
    public static let lampGlow = Ink.walnut5     // e8c170
    public static let labelText = Ink.neutral9   // ebede9
    public static let labelShadow = Ink.neutral0 // 090a14
    public static let outline = Ink.neutral0     // 090a14
    public static let wallDay = Ink.neutral9     // ebede9
    public static let wallDayShade = Ink.neutral8 // c7cfcc
}

// MARK: - Ramp steps

extension Ink {
    /// The ink for `step` (0 = darkest) of `ramp`, clamped to the ramp's range.
    public init(ramp: Apollo.Ramp, step: Int) {
        let r = ramp.indices
        self.init(palette: r.lowerBound + min(max(step, 0), r.count - 1))
    }

    /// The ramp this ink belongs to (nil for `.clear`).
    public var ramp: Apollo.Ramp? { paletteIndex.map { Apollo.ramp(of: $0) } }

    /// Position within its ramp, 0 = darkest (nil for `.clear`).
    public var step: Int? {
        guard let i = paletteIndex else { return nil }
        return i - Apollo.ramp(of: i).indices.lowerBound
    }

    /// `n` steps darker along the same ramp, clamped at its darkest colour. `.clear` stays clear.
    public func darker(_ n: Int = 1) -> Ink {
        guard let ramp, let step else { return self }
        return Ink(ramp: ramp, step: step - n)
    }

    /// `n` steps lighter along the same ramp, clamped at its lightest colour. `.clear` stays clear.
    public func lighter(_ n: Int = 1) -> Ink {
        guard let ramp, let step else { return self }
        return Ink(ramp: ramp, step: step + n)
    }
}
