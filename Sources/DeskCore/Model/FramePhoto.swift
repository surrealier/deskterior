import Foundation

/// A photo hung in the picture frame (Erratum 33): the user's picture as the frame shows it, exactly `size` (26×34) art
/// px, every pixel an opaque Apollo colour, pixelated by the app (`FramePixelator`, DeskPixels) from a file it read once.
/// It never holds the file, its name or its path. `frame.json` keeps it as `rows`.
public struct FramePhoto: Sendable, Equatable, CustomStringConvertible {
    /// The 32×40 framed print's photo window (`DecorArt.photoWindow(in:)`: inside the 2-px oak frame and a 1-px mat).
    public static let size = ArtSize(26, 34)
    /// One character per Apollo index 0…45 (`0`–`9`, `a`–`z`, `A`–`J`), as `rows` spells the pixels.
    public static let alphabet: [Character] = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJ")

    /// `alphabet`'s characters back to their Apollo indices (Erratum 33).
    private static let indexByCharacter: [Character: Int] = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) }
    )

    /// The pixels, row 0 at the top.
    public let image: PixelBuffer

    /// Nil unless `image` is `size` and every pixel is an opaque Apollo colour.
    public init?(_ image: PixelBuffer) {
        guard image.size == Self.size, image.pixels.allSatisfy({ Apollo.index(of: $0) != nil }) else { return nil }
        self.image = image
    }

    /// `size.h` strings of `size.w` `alphabet` characters, top row first; nil for any other shape or character.
    public init?(rows: [String]) {
        guard rows.count == Self.size.h else { return nil }
        var pixels: [RGBA8] = []
        pixels.reserveCapacity(Self.size.w * Self.size.h)
        for row in rows {
            guard row.count == Self.size.w else { return nil }
            for ch in row {
                guard let i = Self.indexByCharacter[ch] else { return nil }
                pixels.append(Apollo.colors[i])
            }
        }
        self.init(PixelBuffer(width: Self.size.w, height: Self.size.h, pixels: pixels))
    }

    /// The pixels as `alphabet` rows (what `frame.json` stores).
    public var rows: [String] {
        (0..<image.height).map { y in
            String((0..<image.width).map { x in Self.alphabet[Apollo.index(of: image[x, y])!] })
        }
    }

    /// A short stable key for the photo (`WallArt.signature`, logs): `digest(image)`.
    public var digest: String { Self.digest(image) }

    /// FNV-1a 64 over `b`'s RGBA bytes, as 16 lower-case hex digits (`String(format: "%016llx", h)`).
    public static func digest(_ b: PixelBuffer) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        b.withUnsafeBytes { for byte in $0 { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 } }
        return String(format: "%016llx", h)
    }

    /// "photo <digest>" (logs and test output never print 884 pixels, or a file name).
    public var description: String { "photo \(digest)" }

    /// Why a token cannot hang in the frame: `.notAPhoto` unless `meta.kind.isImageLike` and it is neither an alias nor a
    /// package; `.photoInCloud` for an iCloud placeholder (reading it would download it); nil when it can.
    public static func refusal(for meta: TokenMeta) -> ToastKey? {
        guard meta.kind.isImageLike, !meta.isAlias, !meta.isPackage else { return .notAPhoto }
        return meta.isDataless ? .photoInCloud : nil
    }

    /// A procedural photo (a sunset over the sea), for the contact sheet (`ArtCatalog.decor()`) and tests.
    public static let sample: FramePhoto = {
        var c = PixelCanvas(width: size.w, height: size.h, fill: .blue2)
        c.gradientV(ArtRect(0, 0, size.w, 20), inks: [.purple2, .red3, .red4, .walnut4])
        c.ellipseFill(ArtRect(9, 13, 8, 8), .walnut5)
        c.fill(ArtRect(0, 20, size.w, 14), .blue2)
        for y in stride(from: 21, to: 30, by: 2) { c.hline(x: (y * 5) % 11, y: y, length: 8, .blue3) }
        c.fill(ArtRect(0, 30, size.w, 4), .oak4)
        return FramePhoto(c.buffer)!
    }()
}

/// `{"size": [26, 34], "rows": [...]}` (Erratum 33): anything else (another size, a short row, a character outside
/// `alphabet`) does not decode, so `FrameDocument` reads it as no photo.
extension FramePhoto: Codable {
    private enum CodingKeys: String, CodingKey { case size, rows }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let size = try c.decode([Int].self, forKey: .size)
        let rows = try c.decode([String].self, forKey: .rows)
        guard size == [Self.size.w, Self.size.h], let photo = FramePhoto(rows: rows) else {
            throw DecodingError.dataCorruptedError(forKey: .rows, in: c, debugDescription: "not a 26×34 Apollo photo")
        }
        self = photo
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode([Self.size.w, Self.size.h], forKey: .size)
        try c.encode(rows, forKey: .rows)
    }
}
