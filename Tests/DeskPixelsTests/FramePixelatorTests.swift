import CoreGraphics
import DeskCore
import Foundation
import ImageIO
import Testing
@testable import DeskPixels

/// The picture frame's photo (Erratum 33): ImageIO's small oriented thumbnail (`ImageThumbnail`), then a centred
/// aspect-fill crop to 26:34, an area average, clear pixels onto the mat's paper and 16 median-cut Apollo colours
/// without dither (`FramePixelator`).
@Suite("Frame pixelator")
struct FramePixelatorTests {
    static func fixture(_ name: String, filePath: String = #filePath) throws -> PixelBuffer {
        let url = Golden.url(name, filePath: filePath)
        return try #require(PNGCodec.decode(try Data(contentsOf: url)), "missing fixture \(url.path)")
    }

    /// `b` encoded in memory as `type` (a UTI), with `properties` on its one image.
    static func encoded(_ b: PixelBuffer, type: String, properties: [CFString: Any] = [:]) throws -> Data {
        let image = try #require(b.makeCGImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out as CFMutableData, type as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// A `w`×`h` opaque buffer coloured by `color(x, y)`.
    static func buffer(_ w: Int, _ h: Int, _ color: (Int, Int) -> RGBA8) -> PixelBuffer {
        var b = PixelBuffer(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w { b[x, y] = color(x, y) }
        }
        return b
    }

    static let red = RGBA8(220, 30, 30, 255)
    static let green = RGBA8(30, 200, 40, 255)
    static let blue = RGBA8(30, 40, 220, 255)

    @Test("The file's orientation is applied: a TIFF tagged 'rotate 90° clockwise' reads upright")
    func orientation() throws {
        let stored = Self.buffer(40, 20) { x, _ in x < 20 ? Self.red : Self.blue }
        let tiff = try Self.encoded(stored, type: "public.tiff", properties: [kCGImagePropertyOrientation: 6])
        let b = try #require(ImageThumbnail.oriented(data: tiff))
        #expect(b.size == ArtSize(20, 40))
        for y in 0..<b.height where y < 18 || y >= 22 {
            for x in 0..<b.width {
                let c = b[x, y]
                let reddish = Int(c.r) > Int(c.b) + 100, bluish = Int(c.b) > Int(c.r) + 100
                #expect(c.a == 255 && (y < 18 ? reddish : bluish), "(\(x),\(y)) \(c)")
            }
        }
        // Without the tag the same pixels stay as stored.
        let plain = try #require(ImageThumbnail.oriented(data: try Self.encoded(stored, type: "public.tiff")))
        #expect(plain.size == ArtSize(40, 20))
        #expect(Int(plain[2, 10].r) > Int(plain[2, 10].b) + 100 && Int(plain[37, 10].b) > Int(plain[37, 10].r) + 100)
    }

    @Test("A large picture is read at most 256 px on its longest side; a small one is never scaled up")
    func bounded() throws {
        let large = Self.buffer(600, 300) { x, y in RGBA8(UInt8(x * 255 / 599), UInt8(y * 255 / 299), 128, 255) }
        let big = try #require(ImageThumbnail.oriented(data: PNGCodec.encode(large)))
        #expect(big.size == ArtSize(256, 128))
        let tall = try #require(ImageThumbnail.oriented(data: PNGCodec.encode(Self.buffer(30, 900) { _, _ in Self.green })))
        #expect(tall.height == 256 && (8...9).contains(tall.width), "\(tall.size)")
        let small = Self.buffer(100, 50) { x, _ in x < 50 ? Self.red : Self.blue }
        let read = try #require(ImageThumbnail.oriented(data: PNGCodec.encode(small)))
        #expect(read.size == ArtSize(100, 50))
        #expect(read == small, "read 1:1, pixel for pixel")
        #expect(ImageThumbnail.oriented(data: PNGCodec.encode(large), maxPixelSize: 60)?.size == ArtSize(60, 30))
    }

    @Test("A header over maxSourcePixels, bytes that are no image and no bytes at all are refused")
    func refusals() throws {
        let png = PNGCodec.encode(Self.buffer(20, 20) { _, _ in Self.green })
        #expect(ImageThumbnail.oriented(data: png, maxSourcePixels: 100) == nil, "400 px claimed, 100 allowed")
        #expect(ImageThumbnail.oriented(data: png, maxSourcePixels: 399) == nil)
        #expect(ImageThumbnail.oriented(data: png, maxSourcePixels: 400)?.size == ArtSize(20, 20), "the limit itself reads")
        #expect(ImageThumbnail.oriented(data: Data("Not a photo, just some text.\n".utf8)) == nil)
        #expect(ImageThumbnail.oriented(data: Data()) == nil)
        #expect(ImageThumbnail.oriented(data: png, maxPixelSize: 0) == nil)
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskterior-frame-missing-\(UUID().uuidString).png", isDirectory: false)
        #expect(ImageThumbnail.oriented(contentsOf: gone) == nil)
        #expect(FramePixelator.photo(contentsOf: gone) == nil)
    }

    @Test("A photo file reads through the thumbnail into a 26×34 frame photo")
    func fromFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskterior-frame-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.fixture("fixture-photo-48x32")
        try TestSupport.writePNG(source, directory: dir.path, name: "photo")
        let url = dir.appendingPathComponent("photo.png", isDirectory: false)
        let before = try Data(contentsOf: url)
        let photo = try #require(FramePixelator.photo(contentsOf: url))
        #expect(photo == FramePixelator.pixelate(source), "the file path and the buffer path agree")
        #expect(try Data(contentsOf: url) == before, "the file is only read")
    }

    @Test("Golden: the photo fixture as the frame shows it (26×34, ≤ 16 opaque Apollo colours)")
    func golden() throws {
        let source = try Self.fixture("fixture-photo-48x32")
        let cut = UInt8((FramePixelator.alphaThreshold * 255).rounded(.up))
        #expect(source.pixels.allSatisfy { $0.a >= cut }, "the fixture has no clear pixel")
        let photo = try #require(FramePixelator.pixelate(source))
        #expect(photo.image.size == FramePhoto.size && FramePhoto.size == ArtSize(26, 34))
        #expect(photo.image.pixels.allSatisfy { $0.a == 255 && Apollo.index(of: $0) != nil })
        let colours = Set(photo.image.pixels)
        #expect(colours.count <= FramePixelator.colors && colours.count >= 4, "\(colours.count) colours")
        #expect(Golden.match(photo.image, "frame-photo-48x32"))
        #expect(FramePixelator.pixelate(source) == photo, "the same input gives the same photo")
        // A picture with clear pixels keeps at most one more colour: the paper.
        let app = try #require(FramePixelator.pixelate(try Self.fixture("fixture-app-64")))
        #expect(Set(app.image.pixels).count <= FramePixelator.colors + 1)
    }

    @Test("No dither: along every row of a grey gradient each colour forms one run")
    func noDither() throws {
        let gradient = Self.buffer(100, 100) { x, _ in
            let v = UInt8(x * 255 / 99)
            return RGBA8(v, v, v, 255)
        }
        let photo = try #require(FramePixelator.pixelate(gradient))
        let b = photo.image
        #expect(Set(b.pixels).count >= 4, "a gradient keeps several greys")
        for y in 0..<b.height {
            #expect(Self.returningColour(b, row: y) == nil, "row \(y): \(String(describing: Self.returningColour(b, row: y)))")
            #expect((0..<b.width).allSatisfy { b[$0, y] == b[$0, 0] }, "row \(y) is row 0")
        }
        // The check bites: the same greys Bayer-dithered (as the polaroid icon is) do come back within a row.
        let crop = WallpaperPixelator.aspectFillCrop(gradient.size, to: FramePhoto.size)
        let averaged = Quantizer.areaAverage(gradient.cropped(to: crop), to: FramePhoto.size)
        let dithered = Quantizer.mapToPalette(averaged, allowed: Quantizer.medianCut(averaged, maxColors: 16), dither: true)
        #expect((0..<dithered.height).contains { Self.returningColour(dithered, row: $0) != nil })
    }

    /// The first `x` in `row` of `b` whose colour already ended a run to its left (nil: every colour is one run).
    static func returningColour(_ b: PixelBuffer, row y: Int) -> Int? {
        var seen: Set<RGBA8> = [b[0, y]]
        for x in 1..<b.width where b[x, y] != b[x - 1, y] {
            if seen.contains(b[x, y]) { return x }
            seen.insert(b[x, y])
        }
        return nil
    }

    @Test("Aspect fill: a wide picture is cropped to its centre")
    func aspectFill() throws {
        let thirds = Self.buffer(300, 100) { x, _ in x < 100 ? Self.red : x < 200 ? Self.green : Self.blue }
        let photo = try #require(FramePixelator.pixelate(thirds))
        let colours = Set(photo.image.pixels)
        #expect(colours.count == 1, "\(colours)")
        let c = try #require(colours.first)
        #expect(c.g > c.r && c.g > c.b, "the centre third is green: \(c)")
    }

    @Test("Clear pixels become the mat's paper exactly; a clear picture is blank paper; an empty one is nil")
    func paper() throws {
        let paper = Ink.neutral9.color
        let size = FramePhoto.size
        let half = size.w / 2
        let blue = Self.buffer(size.w, size.h) { x, _ in x < half ? .clear : Ink.blue3.color }
        let p1 = try #require(FramePixelator.pixelate(blue))
        for y in 0..<size.h {
            for x in 0..<size.w {
                #expect(p1.image[x, y] == (x < half ? paper : Ink.blue3.color), "(\(x),\(y))")
            }
        }
        #expect(Set(p1.image.pixels) == [paper, Ink.blue3.color])

        let nearWhite = Self.buffer(size.w, size.h) { x, _ in
            x < half ? .clear : (x == 19 || x == 20) ? Ink.neutral8.color : RGBA8(250, 248, 240, 255)
        }
        let p2 = try #require(FramePixelator.pixelate(nearWhite))
        for y in 0..<size.h {
            for x in 0..<half { #expect(p2.image[x, y] == paper, "(\(x),\(y)) \(p2.image[x, y])") }
        }
        #expect(Set(p2.image.pixels).count <= FramePixelator.colors + 1)

        // A busy picture (hundreds of colours, none near white): the median cut's 16 boxes leave none to the paper on
        // its own, so the paper is added to the palette and its pixels still come out exactly neutral9.
        let clearAt = [(0, 0), (1, 0), (0, 1), (24, 0), (25, 0), (25, 1)]
        let busy = Self.buffer(size.w, size.h) { x, y in
            if clearAt.contains(where: { $0 == (x, y) }) { return .clear }
            if y < 4 {
                let r = 150 + (x * 9 + y * 3) % 60, g = 140 + (x * 5 + y * 11) % 60, b = 60 + (x * 13 + y * 7) % 60
                return RGBA8(UInt8(r), UInt8(g), UInt8(b), 255)
            }
            let r = (x * 9 + y * 3) % 256, g = (x * 5 + y * 11) % 256, b = (x * 13 + y * 7) % 256
            return RGBA8(UInt8(r), UInt8(g), UInt8(b), 255)
        }
        #expect(Set(busy.pixels).count > FramePixelator.colors * 4, "busy: \(Set(busy.pixels).count) colours")
        let p3 = try #require(FramePixelator.pixelate(busy))
        for (x, y) in clearAt { #expect(p3.image[x, y] == paper, "(\(x),\(y)) \(p3.image[x, y])") }
        #expect(Set(p3.image.pixels).count <= FramePixelator.colors + 1)

        let clear = try #require(FramePixelator.pixelate(PixelBuffer(width: 40, height: 30)))
        #expect(clear.image.pixels.allSatisfy { $0 == paper })
        #expect(FramePixelator.pixelate(PixelBuffer(width: 0, height: 0)) == nil)
        #expect(FramePixelator.pixelate(PixelBuffer(width: 5, height: 0)) == nil)
    }

    @Test("A 62 MP panorama, over the first 50 MP cap, reads through the thumbnail into a 26×34 photo")
    func panorama() throws {
        let w = 16000, h = 3900
        #expect(w * h > 50_000_000 && w * h <= ImageThumbnail.defaultMaxSourcePixels)
        let jpeg = try Self.streamedJPEG(width: w, height: h)
        #expect(jpeg.count < ImageThumbnail.maxSourceBytes, "\(jpeg.count) bytes")
        let b = try #require(ImageThumbnail.oriented(data: jpeg))
        #expect(b.width == ImageThumbnail.defaultMaxPixelSize && (61...63).contains(b.height), "\(b.size)")
        let photo = try #require(FramePixelator.pixelate(b))
        #expect(photo.image.size == FramePhoto.size)
        #expect(photo.image.pixels.allSatisfy { $0.a == 255 && Apollo.index(of: $0) != nil })
        func light(_ c: RGBA8) -> Int { Int(c.r) + Int(c.g) + Int(c.b) }
        #expect(light(photo.image[13, 0]) < light(photo.image[13, 33]), "the ramp runs dark (top) to light (bottom)")
        #expect(ImageThumbnail.oriented(data: jpeg, maxSourcePixels: 50_000_000) == nil, "the first cap refused it")
    }

    /// A `w`×`h` sRGB JPEG of a grey ramp (black at the top, white at the bottom), encoded in memory from rows made as
    /// the encoder asks for them (`CGDataProvider(sequentialInfo:)`), so the full bitmap is never held.
    static func streamedJPEG(width w: Int, height h: Int) throws -> Data {
        final class Ramp {
            let rowBytes: Int, height: Int
            var offset = 0
            init(rowBytes: Int, height: Int) {
                self.rowBytes = rowBytes
                self.height = height
            }
        }
        let ramp = Ramp(rowBytes: w * 3, height: h)
        var callbacks = CGDataProviderSequentialCallbacks(
            version: 0,
            getBytes: { info, buffer, count in
                let r = Unmanaged<Ramp>.fromOpaque(info!).takeUnretainedValue()
                let bytes = buffer.assumingMemoryBound(to: UInt8.self)
                let n = max(0, min(count, r.rowBytes * r.height - r.offset))
                var i = 0
                while i < n {
                    let y = (r.offset + i) / r.rowBytes
                    let run = min(n - i, (y + 1) * r.rowBytes - (r.offset + i))
                    (bytes + i).update(repeating: UInt8(y * 255 / max(r.height - 1, 1)), count: run)
                    i += run
                }
                r.offset += n
                return n
            },
            skipForward: { info, count in
                Unmanaged<Ramp>.fromOpaque(info!).takeUnretainedValue().offset += Int(count)
                return count
            },
            rewind: { info in Unmanaged<Ramp>.fromOpaque(info!).takeUnretainedValue().offset = 0 },
            releaseInfo: nil
        )
        return try withExtendedLifetime(ramp) {
            let provider = try #require(
                CGDataProvider(sequentialInfo: Unmanaged.passUnretained(ramp).toOpaque(), callbacks: &callbacks)
            )
            let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let image = try #require(CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3, space: sRGB,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent
            ))
            let out = NSMutableData()
            let jpeg = "public.jpeg" as CFString
            let dest = try #require(CGImageDestinationCreateWithData(out as CFMutableData, jpeg, 1, nil))
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
            try #require(CGImageDestinationFinalize(dest))
            return out as Data
        }
    }

    @Test("Constants: 16 colours, version 1, a 256-px thumbnail, 250 MP and 64 MB limits")
    func constants() {
        #expect(FramePixelator.colors == 16)
        #expect(FramePixelator.version == 1)
        #expect(FramePixelator.alphaThreshold == IconPixelator.alphaThreshold && FramePixelator.alphaThreshold == 0.45)
        #expect(ImageThumbnail.defaultMaxPixelSize == 256)
        #expect(ImageThumbnail.defaultMaxSourcePixels == 250_000_000)
        #expect(ImageThumbnail.maxSourceBytes == 64 << 20)
    }
}
