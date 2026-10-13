import CoreGraphics
import Foundation
import DeskCore

/// The one CoreGraphics pixel format Deskterior uses: sRGB, 8 bits per component, 32 bits per pixel,
/// premultiplied alpha last, bytes in R, G, B, A order, row 0 = top.
public enum CGBridge {
    public static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    )

    /// A zero-filled (transparent) RGBA8 sRGB bitmap context with nearest-neighbour sampling and no
    /// anti-aliasing. Its backing memory is row 0 = top, even though drawing coordinates are y-up.
    public static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    /// Reads a context created by `makeContext` back into a buffer, un-premultiplying partial alpha. Nil for
    /// any other layout (BGRA, alpha first, no alpha, float components, a colour space other than sRGB), whose
    /// bytes would be misread; draw such images into a `makeContext` context first (`PixelBuffer(cgImage:)`).
    public static func pixelBuffer(from ctx: CGContext) -> PixelBuffer? {
        guard let data = ctx.data, hasOwnLayout(ctx) else { return nil }
        let w = ctx.width, h = ctx.height, rowBytes = ctx.bytesPerRow
        let src = data.bindMemory(to: UInt8.self, capacity: rowBytes * h)
        var px = [RGBA8](repeating: .clear, count: w * h)
        for y in 0..<h {
            let row = src + y * rowBytes
            for x in 0..<w {
                let p = row + x * 4
                px[y * w + x] = unpremultiplied(p[0], p[1], p[2], p[3])
            }
        }
        return PixelBuffer(width: w, height: h, pixels: px)
    }

    /// sRGB, 8 bpc, 32 bpp, integer, premultiplied alpha last, bytes in R, G, B, A order.
    static func hasOwnLayout(_ ctx: CGContext) -> Bool {
        let order = ctx.bitmapInfo.intersection(.byteOrderMask)
        return ctx.bitsPerPixel == 32 && ctx.bitsPerComponent == 8
            && ctx.alphaInfo == .premultipliedLast
            && (order == .byteOrder32Big || order == [])
            && !ctx.bitmapInfo.contains(.floatComponents)
            && ctx.colorSpace?.name == CGColorSpace.sRGB
    }

    @inline(__always)
    static func unpremultiplied(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> RGBA8 {
        switch a {
        case 0: return .clear
        case 255: return RGBA8(r, g, b, 255)
        default:
            let a32 = UInt32(a)
            func un(_ c: UInt8) -> UInt8 { UInt8(min(255, (UInt32(c) * 255 + a32 / 2) / a32)) }
            return RGBA8(un(r), un(g), un(b), a)
        }
    }

    @inline(__always)
    static func premultiplied(_ c: RGBA8) -> (UInt8, UInt8, UInt8, UInt8) {
        switch c.a {
        case 0: return (0, 0, 0, 0)
        case 255: return (c.r, c.g, c.b, 255)
        default:
            let a = UInt32(c.a)
            func pre(_ v: UInt8) -> UInt8 { UInt8((UInt32(v) * a + 127) / 255) }
            return (pre(c.r), pre(c.g), pre(c.b), c.a)
        }
    }
}

extension PixelBuffer {
    /// An sRGB, premultiplied-RGBA8 `CGImage` (row 0 = top). Nil for an empty buffer.
    public func makeCGImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (i, c) in pixels.enumerated() {
            let p = CGBridge.premultiplied(c)
            bytes[i * 4] = p.0
            bytes[i * 4 + 1] = p.1
            bytes[i * 4 + 2] = p.2
            bytes[i * 4 + 3] = p.3
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGBridge.colorSpace, bitmapInfo: CGBridge.bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Converts any `CGImage` (other pixel formats, colour spaces or alpha layouts) by drawing it 1:1 into an
    /// sRGB RGBA8 context. Partial alpha is un-premultiplied and kept; fully transparent pixels become `.clear`.
    /// Nil for an empty image or when CoreGraphics cannot create the context.
    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard let ctx = CGBridge.makeContext(width: w, height: h) else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buffer = CGBridge.pixelBuffer(from: ctx) else { return nil }
        self = buffer
    }
}
