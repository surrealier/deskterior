#if !canImport(ImageIO)
import DeskCore
import Foundation

/// PNG ⇄ `PixelBuffer` where ImageIO does not exist: `PortablePNG`. Same contract as the ImageIO `PNGCodec`.
public enum PNGCodec {
    /// PNG bytes for `b` (sRGB, RGBA8, row 0 = top); empty `Data` for an empty buffer.
    public static func encode(_ b: PixelBuffer) -> Data {
        PortablePNG.encode(b)
    }

    /// Decodes a PNG into RGBA8; nil if it is not a PNG (ImageIO also reads other formats; nothing here needs them).
    public static func decode(_ d: Data) -> PixelBuffer? {
        PortablePNG.decode(d)
    }
}
#endif
