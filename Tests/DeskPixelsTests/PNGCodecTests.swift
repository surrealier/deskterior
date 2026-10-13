import CoreGraphics
import Testing
@testable import DeskCore
@testable import DeskPixels

@Suite("PNGCodec and CGBridge")
struct PNGCodecTests {
    static let red = RGBA8(255, 0, 0), green = RGBA8(0, 255, 0), blue = RGBA8(0, 0, 255)
    static let desk = RGBA8(hex: 0xd7b594)

    /// 3×2, asymmetric in both axes and in every channel:
    /// ```
    /// row 0: red   green  blue
    /// row 1: white clear  d7b594
    /// ```
    static let pattern = PixelBuffer(width: 3, height: 2, pixels: [red, green, blue, .white, .clear, desk])

    @Test("PNG round trip is exact")
    func roundTrip() throws {
        let data = PNGCodec.encode(Self.pattern)
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // IHDR: width then height, big-endian.
        #expect(Array(data[16..<24]) == [0, 0, 0, 3, 0, 0, 0, 2])
        let back = try #require(PNGCodec.decode(data))
        #expect(back == Self.pattern)
        #expect(back[0, 0] == Self.red && back[2, 0] == Self.blue && back[0, 1] == .white && back[2, 1] == Self.desk)
    }

    @Test("CGImage layout: sRGB, 8 bpc, 32 bpp, premultipliedLast, RGBA bytes, row 0 = top")
    func cgImageLayout() throws {
        let image = try #require(Self.pattern.makeCGImage())
        #expect(image.width == 3 && image.height == 2)
        #expect(image.bitsPerComponent == 8 && image.bitsPerPixel == 32 && image.bytesPerRow == 12)
        #expect(image.alphaInfo == .premultipliedLast)
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
        let data = bytes(try #require(image.dataProvider?.data))
        #expect(data == [
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
            255, 255, 255, 255, 0, 0, 0, 0, 0xd7, 0xb5, 0x94, 255,
        ])
        #expect(data == Self.pattern.rgbaBytes)
        #expect(PixelBuffer(cgImage: image) == Self.pattern)
    }

    @Test("Other source formats are converted: BGRA little-endian, grey, partial alpha")
    func foreignFormats() throws {
        // BGRA, premultiplied first, little-endian: bytes B, G, R, A in memory.
        let bgraInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let bgra = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGBridge.colorSpace, bitmapInfo: bgraInfo))
        bgra.clear(CGRect(x: 0, y: 0, width: 2, height: 2))
        bgra.setFillColor(CGColor(colorSpace: CGBridge.colorSpace, components: [1, 0, 0, 1])!)
        bgra.fill(CGRect(x: 0, y: 1, width: 1, height: 1))      // y-up: top-left pixel
        bgra.setFillColor(CGColor(colorSpace: CGBridge.colorSpace, components: [0, 0, 1, 1])!)
        bgra.fill(CGRect(x: 1, y: 0, width: 1, height: 1))      // bottom-right
        let bgraImage = try #require(bgra.makeImage())
        let fromBGRA = try #require(PixelBuffer(cgImage: bgraImage))
        #expect(fromBGRA.pixels == [Self.red, .clear, .clear, Self.blue])

        // 8-bit grey, no alpha.
        let grey = try #require(CGContext(
            data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 2,
            space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGImageAlphaInfo.none.rawValue))
        grey.setFillColor(gray: 1, alpha: 1)
        grey.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        grey.setFillColor(gray: 0, alpha: 1)
        grey.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let greyImage = try #require(grey.makeImage())
        let fromGrey = try #require(PixelBuffer(cgImage: greyImage))
        #expect(fromGrey.pixels == [.white, .black])

        // Partial alpha is un-premultiplied and kept.
        var half = PixelBuffer(width: 1, height: 1)
        half[0, 0] = RGBA8(255, 0, 0, 128)
        let image = try #require(half.makeCGImage())
        let raw = bytes(try #require(image.dataProvider?.data))
        #expect(raw == [128, 0, 0, 128])                   // premultiplied in the CGImage
        #expect(PixelBuffer(cgImage: image)?.pixels == [RGBA8(255, 0, 0, 128)])
    }

    @Test("pixelBuffer(from:) reads only its own RGBA layout (M1 review F15)")
    func contextLayoutIsChecked() throws {
        let own = try #require(CGBridge.makeContext(width: 2, height: 1))
        own.setFillColor(CGColor(colorSpace: CGBridge.colorSpace, components: [1, 0, 0, 1])!)
        own.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(CGBridge.pixelBuffer(from: own)?.pixels == [Self.red, .clear])

        // Same depth, other layouts: reading them as RGBA would swap channels or misread alpha.
        let layouts: [(CGColorSpace, UInt32)] = [
            (CGBridge.colorSpace, CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            (CGBridge.colorSpace, CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            (CGBridge.colorSpace, CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            (CGBridge.colorSpace, CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            (CGColorSpace(name: CGColorSpace.displayP3)!,
             CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        ]
        for (space, info) in layouts {
            let ctx = try #require(CGContext(
                data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: space, bitmapInfo: info))
            #expect(CGBridge.pixelBuffer(from: ctx) == nil, "bitmapInfo \(info) in \(String(describing: space.name))")
        }
        // premultipliedLast with the default byte order is the same RGBA memory layout.
        let defaultOrder = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGBridge.colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        defaultOrder.setFillColor(CGColor(colorSpace: CGBridge.colorSpace, components: [0, 0, 1, 1])!)
        defaultOrder.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(CGBridge.pixelBuffer(from: defaultOrder)?.pixels == [Self.blue])
    }

    @Test("Empty and invalid input")
    func invalid() {
        let empty = PNGCodec.encode(PixelBuffer(width: 0, height: 0))
        #expect(empty.isEmpty)
        #expect(PixelBuffer(width: 0, height: 3).makeCGImage() == nil)
        #expect(PNGCodec.decode(empty) == nil)
        var corrupt = PNGCodec.encode(Self.pattern)
        for i in 0..<16 { corrupt[i] = 0x2A }                    // signature and IHDR header gone
        #expect(PNGCodec.decode(corrupt) == nil)
    }

    /// The bytes of a CFData (test files avoid Foundation; see `TestSupport`).
    private func bytes(_ d: CFData) -> [UInt8] {
        Array(UnsafeBufferPointer(start: CFDataGetBytePtr(d), count: CFDataGetLength(d)))
    }

    @Test("Larger buffer with every palette colour survives a round trip")
    func paletteRoundTrip() throws {
        var b = PixelBuffer(width: 46, height: 3)
        for (i, c) in Apollo.colors.enumerated() {
            b[i, 0] = c
            b[45 - i, 2] = c
        }
        let back = try #require(PNGCodec.decode(PNGCodec.encode(b)))
        #expect(back == b)
    }
}
