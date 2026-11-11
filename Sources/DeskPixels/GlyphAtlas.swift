import DeskCore
import Foundation

/// A pixel font's own glyphs as data (docs/WINDOWS.md, WP4): every scalar the font file maps, with the advance and
/// binary mask CoreText draws for it at the font's native size. Baked on macOS (`deskterior-assets bake-font`) and
/// read where CoreText does not exist, so the text there is the same pixels.
///
/// File layout, little-endian:
///
/// | Offset | Size | Field |
/// |---|---|---|
/// | 0 | 4 | magic `DGLY` |
/// | 4 | 2 | format version (1) |
/// | 6 | 2 | pixel size |
/// | 8 | 2 | line height |
/// | 10 | 2 | baseline (rows above it) |
/// | 12 | 2 | cell margin (columns kept each side of the advance) |
/// | 14 | 2 | reserved, 0 |
/// | 16 | 4 | glyph count N |
/// | 20 | 4 | byte size of the font file it was baked from |
/// | 24 | 4 | CRC-32 of that font file |
/// | 28 | 10 × N | index, by scalar: scalar (4), advance (1), reserved (1), bitmap offset from the bitmaps' start (4) |
/// | 28 + 10N | … | bitmaps: `(advance + 2 × margin) × lineHeight` bits each, rows top down, most significant bit first |
public struct GlyphAtlas: Sendable, Equatable {
    public static let galmuri9FileName = "Galmuri9.glyphs"
    public static let version: UInt16 = 1
    static let magic: [UInt8] = Array("DGLY".utf8)
    static let headerSize = 28
    static let entrySize = 10

    public enum Failure: Error, Equatable {
        case notAnAtlas, unsupportedVersion(Int), truncated, badEntry(Int)
    }

    public let pixelSize: Int
    public let lineHeight: Int
    public let baseline: Int
    public let cellMargin: Int
    /// Size and CRC-32 of the font file the atlas was baked from (`isBaked(from:)`).
    public let fontByteCount: UInt32
    public let fontCRC32: UInt32

    private let scalars: [UInt32]
    private let advances: [UInt8]
    private let offsets: [Int]
    private let bitmaps: [UInt8]

    public var count: Int { scalars.count }

    public init(data: Data) throws(Failure) {
        let b = [UInt8](data)
        guard b.count >= Self.headerSize, Array(b[0..<4]) == Self.magic else { throw .notAnAtlas }
        let version = Int(b.u16(4))
        guard version == Int(Self.version) else { throw .unsupportedVersion(version) }
        pixelSize = Int(b.u16(6))
        lineHeight = Int(b.u16(8))
        baseline = Int(b.u16(10))
        cellMargin = Int(b.u16(12))
        guard pixelSize > 0, lineHeight > 0, baseline <= lineHeight, cellMargin < 64 else { throw .notAnAtlas }
        let n = Int(b.u32(16))
        fontByteCount = b.u32(20)
        fontCRC32 = b.u32(24)
        let bitmapStart = Self.headerSize + n * Self.entrySize
        guard n >= 0, bitmapStart <= b.count else { throw .truncated }
        var scalars: [UInt32] = [], advances: [UInt8] = [], offsets: [Int] = []
        scalars.reserveCapacity(n)
        advances.reserveCapacity(n)
        offsets.reserveCapacity(n)
        let bitmapBytes = b.count - bitmapStart
        var previous: UInt32?
        for i in 0..<n {
            let e = Self.headerSize + i * Self.entrySize
            let scalar = b.u32(e), advance = b[e + 4], offset = Int(b.u32(e + 6))
            let size = Self.bitmapSize(advance: Int(advance), margin: cellMargin, lineHeight: lineHeight)
            guard previous.map({ $0 < scalar }) ?? true, offset + size <= bitmapBytes else { throw .badEntry(i) }
            previous = scalar
            scalars.append(scalar)
            advances.append(advance)
            offsets.append(offset)
        }
        self.scalars = scalars
        self.advances = advances
        self.offsets = offsets
        bitmaps = Array(b[bitmapStart...])
    }

    /// Whether the atlas was baked from exactly these font file bytes.
    public func isBaked(from fontFile: Data) -> Bool {
        UInt32(fontFile.count) == fontByteCount && CRC32.checksum([UInt8](fontFile)) == fontCRC32
    }

    /// The scalars the atlas holds, in order.
    public var allScalars: [Unicode.Scalar] { scalars.compactMap(Unicode.Scalar.init) }

    static func bitmapSize(advance: Int, margin: Int, lineHeight: Int) -> Int {
        ((advance + 2 * margin) * lineHeight + 7) / 8
    }

    private func index(of scalar: Unicode.Scalar) -> Int? {
        var lo = 0, hi = scalars.count - 1
        let v = scalar.value
        while lo <= hi {
            let mid = (lo + hi) / 2
            if scalars[mid] == v { return mid }
            if scalars[mid] < v { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// The advance and mask (`(advance + 2 × cellMargin) × lineHeight`, rows top down) for `scalar`, if held.
    public func glyph(_ scalar: Unicode.Scalar) -> (advance: Int, mask: [Bool])? {
        guard let i = index(of: scalar) else { return nil }
        let advance = Int(advances[i]), width = advance + 2 * cellMargin
        var mask = [Bool](repeating: false, count: width * lineHeight)
        let start = offsets[i]
        for bit in 0..<mask.count where bitmaps[start + bit / 8] & (0x80 >> UInt8(bit % 8)) != 0 {
            mask[bit] = true
        }
        return (advance, mask)
    }

    // MARK: Writing

    /// One glyph to write: its scalar, advance and mask (`(advance + 2 × margin) × lineHeight`).
    public struct Entry: Sendable {
        public var scalar: Unicode.Scalar
        public var advance: Int
        public var mask: [Bool]

        public init(scalar: Unicode.Scalar, advance: Int, mask: [Bool]) {
            self.scalar = scalar
            self.advance = advance
            self.mask = mask
        }
    }

    /// The atlas file for `entries` (any order; sorted by scalar here). The bytes depend only on the inputs.
    public static func encode(
        _ entries: [Entry], pixelSize: Int, lineHeight: Int, baseline: Int, cellMargin: Int, fontFile: Data
    ) -> Data {
        let sorted = entries.sorted { $0.scalar.value < $1.scalar.value }
        var out = magic
        out.appendLE16(version)
        out.appendLE16(UInt16(pixelSize))
        out.appendLE16(UInt16(lineHeight))
        out.appendLE16(UInt16(baseline))
        out.appendLE16(UInt16(cellMargin))
        out.appendLE16(0)
        out.appendLE32(UInt32(sorted.count))
        out.appendLE32(UInt32(fontFile.count))
        out.appendLE32(CRC32.checksum([UInt8](fontFile)))
        var bitmaps: [UInt8] = []
        for e in sorted {
            precondition(e.advance >= 0 && e.advance <= 255, "advance out of range: \(e.advance)")
            precondition(e.mask.count == (e.advance + 2 * cellMargin) * lineHeight, "mask size for \(e.scalar)")
            out.appendLE32(e.scalar.value)
            out.append(UInt8(e.advance))
            out.append(0)
            out.appendLE32(UInt32(bitmaps.count))
            var packed = [UInt8](repeating: 0, count: bitmapSize(advance: e.advance, margin: cellMargin, lineHeight: lineHeight))
            for (bit, on) in e.mask.enumerated() where on { packed[bit / 8] |= 0x80 >> UInt8(bit % 8) }
            bitmaps.append(contentsOf: packed)
        }
        out.append(contentsOf: bitmaps)
        return Data(out)
    }
}

/// `PixelFont`'s glyph source where CoreText does not exist: the atlas for single scalars, and for a character
/// of several scalars (a base and combining marks) their glyphs side by side on integer advances, which is how
/// CoreText draws such a character for `PixelFont` (one glyph per code point, no shaping).
struct AtlasRasterizer: GlyphRasterizer {
    let atlas: GlyphAtlas

    func glyph(for c: Character, in font: PixelFont) -> PixelFont.Glyph? {
        let parts = c.unicodeScalars.map(atlas.glyph)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let glyphs = parts.compactMap { $0 }
        let margin = atlas.cellMargin, height = atlas.lineHeight
        if glyphs.count == 1 {
            let g = glyphs[0]
            return PixelFont.Glyph(advance: g.advance, mask: g.mask, maskWidth: g.advance + 2 * margin, source: .primary)
        }
        let total = glyphs.reduce(0) { $0 + $1.advance }
        let width = total + 2 * margin
        var mask = [Bool](repeating: false, count: width * height)
        var pen = 0
        for g in glyphs {
            let w = g.advance + 2 * margin
            for y in 0..<height {
                for x in 0..<w where g.mask[y * w + x] && pen + x < width { mask[y * width + pen + x] = true }
            }
            pen += g.advance
        }
        return PixelFont.Glyph(advance: total, mask: mask, maskWidth: width, source: .primary)
    }
}

#if canImport(CoreText)
extension GlyphAtlas {
    /// Records what CoreText draws for every scalar `font`'s own file maps (control characters and designed
    /// glyphs left out): the `bake-font` command and `GlyphAtlasTests`.
    public static func bake(_ font: PixelFont, fontFile: Data) -> Data {
        var entries: [Entry] = []
        for s in font.primaryScalars {
            guard s.value >= 0x20, !(0x7F...0x9F).contains(s.value), PixelFont.designedGlyphs[Character(s)] == nil,
                  let g = font.primaryGlyph(s)
            else { continue }
            entries.append(Entry(scalar: s, advance: g.advance, mask: g.mask))
        }
        return encode(entries, pixelSize: font.pixelSize, lineHeight: font.lineHeight, baseline: font.baseline,
                     cellMargin: PixelFont.cellMargin, fontFile: fontFile)
    }
}
#endif

extension [UInt8] {
    fileprivate func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    fileprivate func u32(_ i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
    fileprivate mutating func appendLE16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }
    fileprivate mutating func appendLE32(_ v: UInt32) {
        for k in 0..<4 { append(UInt8(v >> (8 * UInt32(k)) & 0xFF)) }
    }
}
