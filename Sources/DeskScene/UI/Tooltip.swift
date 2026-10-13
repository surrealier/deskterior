import DeskCore
import DeskPixels
import SpriteKit

/// Galmuri9 text drawn the way the scene's UI uses it: lines cropped to the font's ink rows (so boxes hug the
/// text), a 1-px drop shadow, and label pills. Every pixel is an Apollo colour with binary alpha.
enum PixelText {
    /// Rows of a rendered line that ever hold ink (from a probe of tall and deep glyphs), so every line of a
    /// font crops to the same height.
    static func inkRows(_ font: PixelFont) -> Range<Int> {
        if let cached = inkRowsCache[ObjectIdentifier(font)] { return cached }
        let probe = font.render("ÁÉgjpqy|보한글", color: Ink.neutral9.color)
        let b = probe.opaqueBounds()
        let rows = b.isEmpty ? 0..<font.lineHeight : b.minY..<b.maxY
        inkRowsCache[ObjectIdentifier(font)] = rows
        return rows
    }

    private static var inkRowsCache: [ObjectIdentifier: Range<Int>] = [:]

    /// One line in `ink`, cropped to the ink rows (and to the pen's left edge).
    static func line(_ s: String, _ ink: Ink, font: PixelFont) -> PixelBuffer {
        let rows = inkRows(font)
        let full = font.render(s, color: ink.color)
        let left = font.overhang(of: s).left
        return full.cropped(to: ArtRect(left, rows.lowerBound, max(1, full.width - left), rows.count))
    }

    /// A line with a 1-px shadow down-right (1 px wider and taller than `line`).
    static func shadowed(_ s: String, _ ink: Ink, shadow: Ink, font: PixelFont) -> PixelBuffer {
        let text = line(s, ink, font: font)
        var out = PixelBuffer(width: text.width + 1, height: text.height + 1)
        out.blit(silhouette(text, shadow), at: ArtPoint(1, 1))
        out.blit(text, at: .zero)
        return out
    }

    /// `b` with every opaque pixel painted `ink`.
    static func silhouette(_ b: PixelBuffer, _ ink: Ink) -> PixelBuffer {
        var out = b
        let c = ink.color
        out.withUnsafeMutablePixels { px in
            for i in px.indices where px[i].a != 0 { px[i] = c }
        }
        return out
    }

    /// Width of `s` as `line` draws it.
    static func width(_ s: String, font: PixelFont) -> Int {
        font.measure(s) + font.overhang(of: s).right
    }

    /// `s` middle-truncated (extension kept) to `maxWidth`.
    static func truncated(_ s: String, maxWidth: Int, font: PixelFont) -> String {
        TextLayout.middleTruncate(s, maxWidth: maxWidth, advance: font.advance(of:))
    }
}

/// The hover tooltip art (DESIGN §2.1): a dark rounded box with a lit rim and a 1-px shadow, the title in
/// Galmuri9 (middle-truncated to 200 art px, extension kept) and an optional dimmer detail line.
enum TooltipArt {
    static let maxTextWidth = 200
    static let padding = ArtSize(4, 3)
    static let lineGap = 2

    static func render(_ spec: TooltipSpec, font: PixelFont) -> PixelBuffer {
        let title = PixelText.line(PixelText.truncated(spec.title, maxWidth: maxTextWidth, font: font), .neutral9, font: font)
        let detail = spec.detail.map {
            PixelText.line(PixelText.truncated($0, maxWidth: maxTextWidth, font: font), .neutral7, font: font)
        }
        let textW = max(title.width, detail?.width ?? 0)
        let textH = title.height + (detail.map { $0.height + lineGap } ?? 0)
        let w = textW + 2 * padding.w + 1, h = textH + 2 * padding.h + 1
        var c = PixelCanvas(width: w, height: h)
        let box = ArtRect(0, 0, w - 1, h - 1)
        c.roundedRectFill(box.offsetBy(1, 1), radius: 2, .neutral0)
        c.roundedRectFill(box, radius: 2, .neutral4)
        c.roundedRectFill(box.insetBy(1, 1), radius: 1, .neutral1)
        c.hline(x: 2, y: 1, length: box.w - 4, .neutral3)
        c.blit(title, at: ArtPoint(padding.w, padding.h))
        if let detail { c.blit(detail, at: ArtPoint(padding.w, padding.h + title.height + lineGap)) }
        return c.buffer
    }

    /// Top-left for a tooltip of `size` pointing at `anchor`: centred below it (above when it would leave
    /// `bounds` at the bottom), or above it first when `above` (below when it would leave `bounds` at the top);
    /// kept inside `bounds`.
    static func origin(size: ArtSize, anchor: ArtRect, bounds: ArtRect, above: Bool = false) -> ArtPoint {
        let inset = min(2, max(0, (bounds.w - size.w) / 2))
        var x = anchor.midX - size.w / 2
        let under = anchor.maxY + 3, over = anchor.minY - 3 - size.h
        var y: Int
        if above {
            y = over >= bounds.minY + inset ? over : under
        } else {
            y = under + size.h <= bounds.maxY ? under : over
        }
        x = min(max(x, bounds.minX + inset), bounds.maxX - inset - size.w)
        y = min(max(y, bounds.minY + inset), bounds.maxY - inset - size.h)
        return ArtPoint(x, y)
    }
}

/// The L9 tooltip node. It appears after the router's delay and renders once; nothing animates.
final class TooltipView {
    let node = SKSpriteNode()
    private(set) var spec: TooltipSpec?
    /// Canvas rect while shown (the lit pass keeps it at full light).
    private(set) var rect: ArtRect?

    init(z: CGFloat) {
        node.zPosition = z
        node.isHidden = true
    }

    /// Shows `spec` (nil hides); true when something visible changed.
    @discardableResult
    func show(_ spec: TooltipSpec?, font: PixelFont?, bounds: ArtRect, space: ArtSpace) -> Bool {
        guard spec != self.spec else { return false }
        self.spec = spec
        guard let spec, let font else {
            let wasShown = rect != nil
            node.isHidden = true
            rect = nil
            return wasShown
        }
        let image = TooltipArt.render(spec, font: font)
        // The spec's own bounds (the glass) when the tooltip fits in them, else the visible canvas.
        var within = spec.bounds.map { $0.intersection(bounds) } ?? bounds
        if image.width > within.w || image.height > within.h { within = bounds }
        let origin = TooltipArt.origin(size: image.size, anchor: spec.anchor, bounds: within, above: spec.prefersAbove)
        let r = ArtRect(origin: origin, size: image.size)
        node.texture = TextureFactory.texture(image)
        space.place(node, at: r)
        node.isHidden = false
        rect = r
        return true
    }
}
