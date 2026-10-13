import CoreGraphics
import DeskCore

/// Turns a desktop picture into a screen wallpaper for the in-scene monitor (DESIGN §1.4): aspect-fill crop,
/// area-average down to the screen, median-cut to a few Apollo colours, Bayer-dithered. Only pictures under the
/// system wallpaper folders load automatically (anything else could raise a TCC prompt).
public enum WallpaperPixelator {
    /// Folders whose pictures may be read without asking.
    public static let allowedRoots = ["/System/Library/Desktop Pictures", "/Library/Desktop Pictures"]

    /// True when `realPath` (already symlink-resolved) lies inside an allowed folder.
    public static func isAllowed(realPath: String) -> Bool {
        allowedRoots.contains { root in realPath.hasPrefix(root + "/") }
    }

    /// The wallpaper at `size` (default: the monitor screen), or nil for an empty image.
    public static func pixelate(_ image: CGImage, to size: ArtSize = CoreLayout.screen.size, colors: Int = 16) -> PixelBuffer? {
        guard let buffer = PixelBuffer(cgImage: image) else { return nil }
        return pixelate(buffer, to: size, colors: colors)
    }

    /// The pure pipeline on an RGBA buffer.
    public static func pixelate(_ source: PixelBuffer, to size: ArtSize, colors: Int = 16) -> PixelBuffer {
        guard source.width > 0, source.height > 0, size.w > 0, size.h > 0 else {
            return PixelBuffer(width: max(0, size.w), height: max(0, size.h), fill: Role.screenOff.color)
        }
        let crop = aspectFillCrop(source.size, to: size)
        let averaged = Quantizer.areaAverage(source.cropped(to: crop), to: size)
        var opaque = Quantizer.thresholdAlpha(averaged, at: 0)
        opaque.withUnsafeMutablePixels { px in
            for i in px.indices where px[i].a == 0 { px[i] = Role.screenOff.color }
        }
        let palette = Quantizer.medianCut(opaque, maxColors: max(2, colors))
        return Quantizer.mapToPalette(opaque, allowed: palette.isEmpty ? nil : palette, dither: true)
    }

    /// The centred source rect with the target's aspect ratio.
    public static func aspectFillCrop(_ source: ArtSize, to target: ArtSize) -> ArtRect {
        // Compare source.w / source.h with target.w / target.h in integers.
        if source.w * target.h > target.w * source.h {
            let w = max(1, source.h * target.w / target.h)
            return ArtRect((source.w - w) / 2, 0, w, source.h)
        } else {
            let h = max(1, source.w * target.h / target.w)
            return ArtRect(0, (source.h - h) / 2, source.w, h)
        }
    }
}
