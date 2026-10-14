/// The app icon (docs/DESIGN.md §6): a desk at night — an anglepoise lamp pooling warm light on the oak, a
/// monitor glowing with desktop files, and a potted plant — in `SpriteKey.standard` inks.
/// The wall is the lamp-lit night blue (`blue1` over `blue2`, not the room's darkest) and the monitor's bezel grey, so
/// the body's top edge holds against a dark Dock and the monitor stands off the wall at 16–32 px (Errata 26).
///
/// The shape follows what macOS 26 accepts as a native icon (checked with `NSWorkspace.icon(forFile:)` on
/// 26.6): a body on Apple's 824/1024 grid with squircle corners. macOS 26 puts full-bleed art with transparent
/// corners, pixel-stepped corners, and any supplied 16- or 32-px image on a grey legacy-icon plate, so:
/// - `artwork` is a square 26-px body in the 32-px canvas, and `shapeContains` cuts the corners at each size;
/// - `iconset` holds the slots from 64 px up only (macOS derives the small sizes from the 64-px image);
/// - `allSlots` adds the 16- and 32-px slots (`small` and `master`), crisp on macOS 14–15 but plated on 26.
///
/// Every slot from 32 px up is an integer nearest-neighbour upscale of `artwork`, clipped by `shapeContains`.
public enum AppIconArt {
    /// 32×32 canvas holding the square 26×26 body (3-px transparent margins); `shapeContains` cuts its corners.
    public static let artwork = IndexedSprite(artworkArt)

    /// The 32×32 master: `artwork` clipped by `shapeContains` at 32 px.
    public static let master = clipped(artwork, scale: 1)

    /// 16×16 variant redrawn for the 16-px slot: 14×14 body with its own corners, 1-px margins.
    public static let small = IndexedSprite(smallArt)

    /// ASCII source of `artwork` (`.` is transparent).
    public static let artworkArt = """
        ................................
        ................................
        ................................
        ...wwwwwwwwwwwwwwwwwwwwwwwwww...
        ...wwwwwwwwwwwwwwwwwwwwwwwwww...
        ...wwwwwwwwww44444444444444ww...
        ...wwwwwFFww4344444444444444w...
        ...wwwwFGGFw4322222222222224w...
        ...wwwwFGGGF432yyyttttttt224w...
        ...wwwwwNNNN432yNNtt97t9t224w...
        ...www6ww99w432tBBBt99tgf224w...
        ...ee6eeeeee432tBBBt99tff224e...
        ...ee6eeeeee432tttttttttt224e...
        ...e5eeeeeee432rrrrrrrrrrfgge...
        ...e6eeeeeee4322222222f2dffgf...
        ...ee6eeeeeee32222222222ddffd...
        ...ee6eeeeeeeeeeee433eeeeddde...
        ...ee6eeeeeeeeeeee433eeeeVVVe...
        ...eee6eeeeeeeeeee433eeeeCCXe...
        ...vvv6vvvvvvvvv2222222vvCCXv...
        ...bnFFFnnnnnnbcccccccccccccc...
        ...nDDDDDnnnnnnbbbbbbbbbbbbbb...
        ...bbnnnnnnnnbbbbbbbbbbbbbbbb...
        ...nnnnnnnnnnnnnnnnnnnnnnnnnn...
        ...vvvvvvvvvvvvvvvvvvvvvvvvvv...
        ...ccvvvvvvcccccccccvvvvccccc...
        ...ccccccccccxxxxxccccccxxxcc...
        ...xxxxxxxxxxxxxxxxxxxxxxxxxx...
        ...zzzzzzzzzzzzzzzzzzzzzzzzzz...
        ................................
        ................................
        ................................
        """

    /// ASCII source of `small`.
    public static let smallArt = """
        ................
        ...wwwwwwwwww...
        ..wwww44444444..
        .wFFww3yytttt2w.
        .FGGFw3tNBt9t2w.
        .wNNNw3tBBt9t2w.
        .e6eee3rrrrrr2e.
        .e6eee322222f2e.
        .ee6eeeee33eeee.
        .vv6vvvv2222vvv.
        .nDDDnnbccccbbb.
        .bnnnnnbbbbbbbb.
        .nnnnnnnnnnnnnn.
        ..cccccccccccc..
        ...zzzzzzzzzz...
        ................
        """

    /// Whether pixel `(x, y)` of a `size`-px icon lies inside the macOS icon shape: Apple's 824/1024 body,
    /// approximated by the superellipse |u|⁵ + |v|⁵ ≤ 1 and sampled at pixel centres.
    public static func shapeContains(_ x: Int, _ y: Int, size: Int) -> Bool {
        let half = 412.0 / 1024.0 * Double(size), centre = Double(size) / 2
        let u = abs(Double(x) + 0.5 - centre) / half, v = abs(Double(y) + 0.5 - centre) / half
        return u * u * u * u * u + v * v * v * v * v <= 1
    }

    /// `sprite` upscaled by `scale`, with every pixel outside the icon shape cleared.
    static func clipped(_ sprite: IndexedSprite, scale: Int) -> IndexedSprite {
        let size = sprite.w * scale
        var inks: [Ink] = []
        inks.reserveCapacity(size * size)
        for y in 0..<size {
            for x in 0..<size {
                inks.append(shapeContains(x, y, size: size) ? sprite[x / scale, y / scale] : .clear)
            }
        }
        return IndexedSprite(w: size, h: size, inks: inks)
    }

    /// One PNG of a macOS `.iconset` folder, as `iconutil` expects it.
    public struct IconsetImage: Hashable, Sendable {
        /// File name inside `AppIcon.iconset`, e.g. `icon_16x16@2x.png`.
        public let name: String
        /// Edge length in pixels.
        public let pixels: Int

        /// The image at `pixels`×`pixels`: `small` for 16 px, otherwise `artwork` scaled up and clipped.
        public func render() -> PixelBuffer {
            if pixels == AppIconArt.small.w { return AppIconArt.small.render() }
            return AppIconArt.clipped(AppIconArt.artwork, scale: pixels / AppIconArt.artwork.w).render()
        }
    }

    /// All ten `.iconset` slots: 16, 32, 128, 256 and 512 pt, each at 1× and 2×.
    public static let allSlots: [IconsetImage] = [16, 32, 128, 256, 512].flatMap { pt in
        [
            IconsetImage(name: "icon_\(pt)x\(pt).png", pixels: pt),
            IconsetImage(name: "icon_\(pt)x\(pt)@2x.png", pixels: pt * 2),
        ]
    }

    /// The slots that go into the shipped icon: 64 px and up (see the type documentation).
    public static let iconset: [IconsetImage] = allSlots.filter { $0.pixels >= 64 }
}
