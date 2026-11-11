import DeskCore
import DeskPixels
import Foundation
#if canImport(SpriteKit)
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
#if canImport(SpriteKit)
import SpriteKit
#else
import DeskStage
#endif
#else
import DeskStage
#endif

/// The only place Deskterior creates `SKTexture`s (DESIGN §1.1): every texture samples `.nearest` and has no
/// mipmaps. Buffers are row 0 = top, like every `PixelBuffer`.
public enum TextureFactory {
    /// Whether `SKTexture(data:size:)` reads its rows bottom-up. SpriteKit does not document the order;
    /// `TextureFactoryTests` pins it by rendering an asymmetric pattern through `SKRenderer`.
    static let dataRowsAreBottomUp = true

    /// A texture for art that does not change, uploaded through `CGImage`.
    public static func texture(_ buffer: PixelBuffer) -> SKTexture {
        #if canImport(SpriteKit)
        guard let image = buffer.makeCGImage() else { return solid(.clear) }
        return recorded(configured(SKTexture(cgImage: image)), buffer)
        #else
        guard buffer.width > 0, buffer.height > 0 else { return solid(.clear) }
        return configured(SKTexture(pixels: buffer))
        #endif
    }

    /// A texture for art that is rebuilt often (every frame if need be): `SKTexture(data:size:)` is synchronous,
    /// so the new pixels show in the very next render (SPIKES S8).
    public static func dynamicTexture(_ buffer: PixelBuffer) -> SKTexture {
        guard buffer.width > 0, buffer.height > 0 else { return solid(.clear) }
        let w = buffer.width, h = buffer.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let src = (dataRowsAreBottomUp ? h - 1 - row : row) * w
            var o = row * w * 4
            for x in 0..<w {
                let c = buffer.pixels[src + x]
                bytes[o] = c.r
                bytes[o + 1] = c.g
                bytes[o + 2] = c.b
                bytes[o + 3] = c.a
                o += 4
            }
        }
        return recorded(dataTexture(bytes, width: w, height: h), buffer)
    }

    /// One texel of `color`; stretched over any node size it stays a flat fill.
    public static func solid(_ color: RGBA8) -> SKTexture {
        recorded(dataTexture([color.r, color.g, color.b, color.a], width: 1, height: 1),
                 PixelBuffer(width: 1, height: 1, fill: color))
    }

    // MARK: Pixels of a texture (docs/WINDOWS.md, WP2)

    #if canImport(SpriteKit)
    /// While true, every texture made here remembers its pixels (row 0 = top) for `pixels(of:)`. Only tests turn
    /// it on (`SoftRasterParityTests`): the app never reads a texture back.
    static var recordsPixels = false

    private final class PixelBox: NSObject {
        let pixels: PixelBuffer
        init(_ pixels: PixelBuffer) { self.pixels = pixels }
    }

    private static let recordedPixels = NSMapTable<SKTexture, PixelBox>.weakToStrongObjects()

    private static func recorded(_ texture: SKTexture, _ buffer: PixelBuffer) -> SKTexture {
        if recordsPixels { recordedPixels.setObject(PixelBox(buffer), forKey: texture) }
        return texture
    }

    /// The pixels a texture was made from (row 0 = top), when it was made here while `recordsPixels` was on.
    static func pixels(of texture: SKTexture) -> PixelBuffer? {
        recordedPixels.object(forKey: texture)?.pixels
    }
    #else
    private static func recorded(_ texture: SKTexture, _ buffer: PixelBuffer) -> SKTexture { texture }

    /// The pixels a texture holds (row 0 = top).
    static func pixels(of texture: SKTexture) -> PixelBuffer? { texture.pixels }
    #endif

    /// Raw `SKTexture(data:size:)` with RGBA bytes in SpriteKit's own row order (see `dataRowsAreBottomUp`).
    static func dataTexture(_ bytes: [UInt8], width: Int, height: Int) -> SKTexture {
        configured(SKTexture(data: Data(bytes), size: CGSize(width: width, height: height)))
    }

    private static func configured(_ texture: SKTexture) -> SKTexture {
        texture.filteringMode = .nearest
        texture.usesMipmaps = false
        return texture
    }
}
