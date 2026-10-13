import CoreGraphics
import DeskCore

/// Turns a real icon or thumbnail into a 16×16 (or 12×12) on-palette token icon (DESIGN §3.4): trim to the
/// alpha bounding box, area-average down, threshold alpha at 0.45, snap to Apollo in OKLab (photos: 16
/// median-cut colours with Bayer dither), drop orphan pixels, add a 1-px outline. Images sit in a polaroid
/// frame (14×14 at 16 px). Every opaque output pixel is an Apollo colour; alpha is binary.
public enum IconPixelator {
    /// Part of the icon-cache key: bump whenever the output for the same input can change.
    public static let version = 1
    public static let alphaThreshold = 0.45
    public static let photoColors = 16

    public enum Style: String, Sendable, CaseIterable {
        /// Icons: every Apollo colour, no dither.
        case icon
        /// Video frames: 16 colours with Bayer dither.
        case photo
        /// Pictures: a photo inside a white frame with a deeper bottom border.
        case polaroid
    }

    public static func style(for kind: FileKind) -> Style {
        switch kind {
        case .image, .screenshot: .polaroid
        case .video: .photo
        // Page thumbnails (PDF) are mostly paper and text lines; dither would only add noise.
        default: .icon
        }
    }

    public static func pixelate(_ image: CGImage, size: Int = 16, style: Style) -> PixelBuffer? {
        PixelBuffer(cgImage: image).flatMap { pixelate($0, size: size, style: style) }
    }

    /// Nil when nothing survives the alpha threshold (callers fall back to the kind icon).
    public static func pixelate(_ source: PixelBuffer, size: Int = 16, style: Style) -> PixelBuffer? {
        precondition(size >= 8, "icon size too small: \(size)")
        let cut = UInt8((alphaThreshold * 255).rounded(.up))
        let bounds = alphaBounds(source, minAlpha: cut)
        guard !bounds.isEmpty else { return nil }
        let trimmed = source.cropped(to: bounds)
        let outline = Role.outline.color

        switch style {
        case .icon, .photo:
            let inner = size - 2
            let fit = fitted(trimmed.size, into: ArtSize(inner, inner))
            let small = Quantizer.thresholdAlpha(Quantizer.areaAverage(trimmed, to: fit), at: alphaThreshold)
            let mapped = style == .icon
                ? Quantizer.mapToPalette(small)
                : Quantizer.mapToPalette(small, allowed: palette(small), dither: true)
            let clean = Quantizer.removeOrphans(mapped)
            guard clean.opaqueBounds() != .zero else { return nil }
            var out = PixelBuffer(width: size, height: size)
            out.blit(clean, at: ArtPoint((size - fit.w) / 2, (size - fit.h) / 2))
            return Quantizer.outline(out, color: outline)

        case .polaroid:
            let frame = size - 2
            let photoSize = ArtSize(frame - 2, frame - 4)
            let cropped = trimmed.cropped(to: coverCrop(trimmed.size, aspect: photoSize))
            var photo = Quantizer.thresholdAlpha(Quantizer.areaAverage(cropped, to: photoSize), at: alphaThreshold)
            let paper = Ink.neutral9.color
            photo.withUnsafeMutablePixels { px in
                for i in px.indices where px[i].a == 0 { px[i] = paper }
            }
            let mapped = Quantizer.mapToPalette(photo, allowed: palette(photo), dither: true)
            var out = PixelBuffer(width: size, height: size)
            out.fill(ArtRect(1, 1, frame, frame), paper)
            out.fill(ArtRect(1, frame, frame, 1), Ink.neutral7.color)
            out.blit(mapped, at: ArtPoint(2, 2), alphaTest: false)
            return Quantizer.outline(out, color: outline)
        }
    }

    // MARK: Private

    /// Up to `photoColors` Apollo indices for `b` (median cut in OKLab).
    private static func palette(_ b: PixelBuffer) -> [Int]? {
        let indices = Quantizer.medianCut(b, maxColors: photoColors)
        return indices.isEmpty ? nil : indices
    }

    /// Bounding box of pixels with alpha ≥ `minAlpha` (soft drop shadows do not count).
    static func alphaBounds(_ b: PixelBuffer, minAlpha: UInt8) -> ArtRect {
        var minX = b.width, minY = b.height, maxX = -1, maxY = -1
        for y in 0..<b.height {
            for x in 0..<b.width where b.pixels[y * b.width + x].a >= minAlpha {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? .zero : ArtRect(minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// The largest size with `s`'s aspect ratio inside `box` (at least 1×1).
    static func fitted(_ s: ArtSize, into box: ArtSize) -> ArtSize {
        let scale = min(Double(box.w) / Double(s.w), Double(box.h) / Double(s.h))
        return ArtSize(
            min(box.w, max(1, Int((Double(s.w) * scale).rounded()))),
            min(box.h, max(1, Int((Double(s.h) * scale).rounded())))
        )
    }

    /// The centred crop of a `s`-sized image with `aspect`'s width:height ratio.
    static func coverCrop(_ s: ArtSize, aspect: ArtSize) -> ArtRect {
        if s.w * aspect.h > s.h * aspect.w {
            let w = max(1, s.h * aspect.w / aspect.h)
            return ArtRect((s.w - w) / 2, 0, w, s.h)
        }
        let h = max(1, s.w * aspect.h / aspect.w)
        return ArtRect(0, (s.h - h) / 2, s.w, h)
    }
}
