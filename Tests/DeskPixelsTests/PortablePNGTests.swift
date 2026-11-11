import DeskCore
import Foundation
import Testing
@testable import DeskPixels

#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

@Suite("PortablePNG")
struct PortablePNGTests {
    static let red = RGBA8(255, 0, 0), green = RGBA8(0, 255, 0), blue = RGBA8(0, 0, 255)
    static let pattern = PixelBuffer(width: 3, height: 2, pixels: [red, green, blue, .white, .clear, RGBA8(hex: 0xd7b594)])

    /// Every PNG checked into the repository's test goldens.
    static var goldenURLs: [URL] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let url = files?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "png", url.path.contains("Goldens") { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    @Test("Round trip is exact, header is PNG with the right size")
    func roundTrip() throws {
        let data = PortablePNG.encode(Self.pattern)
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(Array(data[16..<24]) == [0, 0, 0, 3, 0, 0, 0, 2])
        #expect(try PortablePNG.decodeOrThrow(data) == Self.pattern)
    }

    @Test("Round trip of larger art: every row filter and long LZ77 matches")
    func roundTripLarge() throws {
        var rng = SplitMix64(seed: 7)
        var b = PixelBuffer(width: 301, height: 97)
        for y in 0..<b.height {
            for x in 0..<b.width {
                // Runs of flat colour (matches), gradients (Sub/Up/Paeth) and noise (literals), plus clear pixels.
                let n = rng.next()
                let c: RGBA8 = switch (y / 10) % 4 {
                case 0: RGBA8(UInt8(x & 0xFF), UInt8(y), 40, 255)
                case 1: (x / 7) % 2 == 0 ? .clear : RGBA8(200, 30, 60, 255)
                case 2: RGBA8(UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), 255)
                default: RGBA8(9, 10, 20, 255)
                }
                b[x, y] = c
            }
        }
        let data = PortablePNG.encode(b)
        #expect(try PortablePNG.decodeOrThrow(data) == b)
        #expect(data.count < b.width * b.height * 4 / 2, "compresses: \(data.count) bytes")
    }

    @Test("Empty buffer has no PNG form")
    func empty() {
        #expect(PortablePNG.encode(PixelBuffer(width: 0, height: 0)).isEmpty)
    }

    @Test("Not a PNG, truncated data and bad zlib are refused, never a crash")
    func refusals() {
        let good = PortablePNG.encode(Self.pattern)
        #expect(PortablePNG.decode(Data([1, 2, 3])) == nil)
        for cut in [9, 20, 33, good.count - 13] {
            #expect(PortablePNG.decode(good.prefix(cut)) == nil, "cut at \(cut)")
        }
        var damaged = [UInt8](good)
        if let idat = damaged.indices.first(where: { i in i + 4 <= damaged.count && damaged[i..<(i + 4)] == [73, 68, 65, 84] }) {
            for i in (idat + 6)..<min(damaged.count, idat + 14) { damaged[i] ^= 0xA5 }
        }
        _ = PortablePNG.decode(Data(damaged)) // damaged deflate data: refused or decoded, but no crash
    }

    @Test("Partial alpha goes through premultiplication as on macOS; zero alpha becomes clear")
    func alpha() {
        #expect(PortablePNG.throughPremultiplied(RGBA8(10, 20, 30, 0)) == .clear)
        #expect(PortablePNG.throughPremultiplied(RGBA8(10, 20, 30, 255)) == RGBA8(10, 20, 30, 255))
        let half = PortablePNG.throughPremultiplied(RGBA8(255, 101, 3, 128))
        #expect(half.a == 128 && half.r == 255)
    }

    @Test("Every golden in the repository decodes")
    func goldensDecode() throws {
        let urls = Self.goldenURLs
        #expect(urls.count > 30)
        for url in urls {
            let data = try Data(contentsOf: url)
            #expect(PortablePNG.decode(data) != nil, "\(url.lastPathComponent)")
        }
    }

    #if canImport(ImageIO)
    @Test("Decodes every golden exactly as ImageIO does")
    func matchesImageIO() throws {
        for url in Self.goldenURLs {
            let data = try Data(contentsOf: url)
            let mine = try PortablePNG.decodeOrThrow(data)
            let theirs = try #require(PNGCodec.decode(data))
            #expect(mine == theirs, "\(url.lastPathComponent)")
        }
    }

    @Test("ImageIO reads what this encoder writes")
    func imageIOReadsOurs() throws {
        let data = PortablePNG.encode(Self.pattern)
        #expect(PNGCodec.decode(data) == Self.pattern)
    }
    #endif
}
