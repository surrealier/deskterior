import CoreGraphics
import DeskCore
import Foundation
import ImageIO

/// PNG ⇄ `PixelBuffer` through ImageIO. Encodes to memory only; callers that persist PNGs do the writing.
public enum PNGCodec {
    private static var pngType: CFString { "public.png" as CFString }

    /// PNG bytes for `b` (sRGB, RGBA8, row 0 = top). Returns empty `Data` when the buffer is empty
    /// (0×0 has no PNG form) or ImageIO fails.
    public static func encode(_ b: PixelBuffer) -> Data {
        guard let image = b.makeCGImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, pngType, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return out as Data
    }

    /// Decodes the first image in `d` (any format ImageIO reads) into sRGB RGBA8; nil if it is not an image.
    public static func decode(_ d: Data) -> PixelBuffer? {
        guard
            let src = CGImageSourceCreateWithData(d as CFData, nil),
            CGImageSourceGetCount(src) > 0,
            let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return PixelBuffer(cgImage: image)
    }
}
