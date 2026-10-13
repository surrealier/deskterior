import CoreGraphics
import DeskCore
import DeskPixels
import Foundation
import SpriteKit

/// The only place Deskterior creates `SKTexture`s (DESIGN §1.1): every texture samples `.nearest` and has no
/// mipmaps. Buffers are row 0 = top, like every `PixelBuffer`.
public enum TextureFactory {
    /// Whether `SKTexture(data:size:)` reads its rows bottom-up. SpriteKit does not document the order;
    /// `TextureFactoryTests` pins it by rendering an asymmetric pattern through `SKRenderer`.
    static let dataRowsAreBottomUp = true

    /// A texture for art that does not change, uploaded through `CGImage`.
    public static func texture(_ buffer: PixelBuffer) -> SKTexture {
        guard let image = buffer.makeCGImage() else { return solid(.clear) }
        return configured(SKTexture(cgImage: image))
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
        return dataTexture(bytes, width: w, height: h)
    }

    /// One texel of `color`; stretched over any node size it stays a flat fill.
    public static func solid(_ color: RGBA8) -> SKTexture {
        dataTexture([color.r, color.g, color.b, color.a], width: 1, height: 1)
    }

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
