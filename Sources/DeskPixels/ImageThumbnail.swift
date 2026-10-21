import CoreGraphics
import DeskCore
import Foundation
import ImageIO

/// A picture read small (Erratum 33): ImageIO's thumbnail of the first image, the file's orientation (EXIF/HEIF)
/// applied, its longest side at most `maxPixelSize`. Never decoded at full size: a 12 MP photo decoded whole peaked
/// over 200 MB against §5's 150 MB, while the thumbnail path decodes JPEG, HEIC, PNG and compressed TIFF incrementally
/// (a 49 MP PNG, LZW TIFF or JPEG peaked at 15–21 MB RSS; a 62 MP HEIC panorama, or a 200 MP JPEG or PNG under 64 MB,
/// at 33–44 MB). ImageIO maps the file it reads, though, so an uncompressed source counts its whole size against RSS
/// (a 196 MB uncompressed TIFF peaked at 210 MB): callers refuse a file larger than `maxSourceBytes` by its size alone
/// (`FramePhotoLoader.refusal`, resource values, never read), and a header claiming more than `maxSourcePixels` is
/// refused here before any pixel is decoded (a decompression bomb).
public enum ImageThumbnail {
    /// The longest side of the thumbnail read (Erratum 33): about ten times the frame's photo, plenty for its area
    /// average, and small enough to decode in a few MB.
    public static let defaultMaxPixelSize = 256
    /// The largest image a header may claim (250 MP, Erratum 33: room for 200 MP phone photos, 102 MP medium format and
    /// 63 MP panoramas); a larger one is refused before any pixel is decoded.
    public static let defaultMaxSourcePixels = 250_000_000
    /// The largest file a photo is read from (64 MB); larger ones are refused unread.
    public static let maxSourceBytes = 64 << 20

    /// Nil when `url` is not an image ImageIO reads, or its header is larger than `maxSourcePixels`.
    public static func oriented(contentsOf url: URL, maxPixelSize: Int = defaultMaxPixelSize,
                                maxSourcePixels: Int = defaultMaxSourcePixels) -> PixelBuffer?
    {
        // Read-only: ImageIO opens the file for reading and nothing is ever written (Erratum 33).
        guard let src = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return oriented(src, maxPixelSize: maxPixelSize, maxSourcePixels: maxSourcePixels)
    }

    /// The same for image bytes in memory (tests).
    public static func oriented(data: Data, maxPixelSize: Int = defaultMaxPixelSize,
                                maxSourcePixels: Int = defaultMaxSourcePixels) -> PixelBuffer?
    {
        guard !data.isEmpty, let src = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return oriented(src, maxPixelSize: maxPixelSize, maxSourcePixels: maxSourcePixels)
    }

    // MARK: Private

    /// The source is not cached: the thumbnail is its only decode (Erratum 33).
    private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    /// The first image's header checked against `maxSourcePixels`, then its oriented thumbnail at most `maxPixelSize`
    /// on its longest side (never scaled up), as sRGB RGBA8 (`PixelBuffer(cgImage:)`).
    private static func oriented(_ src: CGImageSource, maxPixelSize: Int, maxSourcePixels: Int) -> PixelBuffer? {
        guard maxPixelSize > 0, CGImageSourceGetCount(src) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0
        else { return nil }
        let (pixels, overflow) = w.multipliedReportingOverflow(by: h)
        guard !overflow, pixels <= maxSourcePixels else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(src, 0, options) else { return nil }
        return PixelBuffer(cgImage: thumbnail)
    }
}
