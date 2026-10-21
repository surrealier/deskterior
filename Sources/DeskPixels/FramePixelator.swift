import CoreGraphics
import DeskCore
import Foundation

/// The picture frame's photo (Erratum 33): a centred aspect-fill crop to 26:34, an area average down to
/// `FramePhoto.size`, alpha below `alphaThreshold` onto the mat's paper (neutral9, as the polaroid icon does), then
/// `colors` median-cut Apollo colours in OKLab — plus the paper itself whenever a pixel was clear, so paper stays
/// paper — mapped without dither. Pure after the read; run once per hang, off the main thread; nothing re-quantizes
/// per frame or per light change.
///
/// No dither (DESIGN §1.2 forbids 1-px checker dithers on large flat areas, and a photo's sky, wall or skin is one; at
/// 26 px a 4-px Bayer period reads as texture, not tone), and 16 colours (`IconPixelator.photoColors`): fewer collapse
/// skin and sky ramps into posters at this size, more rarely survive the snap of box means onto Apollo.
public enum FramePixelator {
    /// Part of what a hung photo looks like: bump when the output for the same input can change.
    public static let version = 1
    /// The most median-cut colours a photo keeps (the paper may add one more, Erratum 33).
    public static let colors = 16
    /// Alpha below this (0…1) shows the mat's paper (`IconPixelator.alphaThreshold`, 0.45).
    public static let alphaThreshold = IconPixelator.alphaThreshold   // 0.45

    /// The pipeline on an RGBA buffer; nil for an empty one.
    public static func pixelate(_ source: PixelBuffer) -> FramePhoto? {
        guard source.width > 0, source.height > 0 else { return nil }
        let size = FramePhoto.size
        let crop = WallpaperPixelator.aspectFillCrop(source.size, to: size)
        var photo = Quantizer.thresholdAlpha(Quantizer.areaAverage(source.cropped(to: crop), to: size), at: alphaThreshold)
        let paper = Ink.neutral9.color
        var hadClear = false
        photo.withUnsafeMutablePixels { px in
            for i in px.indices where px[i].a == 0 { px[i] = paper; hadClear = true }
        }
        var palette = Quantizer.medianCut(photo, maxColors: colors)
        // Paper stays exactly paper: a box mean need not snap to neutral9, and the nearest allowed colour then would not
        // be it (Quantizer.mapToPalette maps every pixel, paper included, to the nearest allowed index).
        if hadClear, let p = Apollo.index(of: paper), !palette.contains(p) { palette.append(p); palette.sort() }
        return FramePhoto(Quantizer.mapToPalette(photo, allowed: palette.isEmpty ? nil : palette, dither: false))
    }

    /// `ImageThumbnail.oriented(contentsOf:)` then `pixelate`; nil when the file is no readable image. (The caller
    /// refuses by size first: `FramePhotoLoader`.)
    public static func photo(contentsOf url: URL) -> FramePhoto? {
        ImageThumbnail.oriented(contentsOf: url).flatMap(pixelate)
    }
}
