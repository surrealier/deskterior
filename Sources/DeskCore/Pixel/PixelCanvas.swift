/// A drawing surface for procedural furniture: a `PixelBuffer` plus ink-based pixel-art primitives.
///
/// Every operation clips to the buffer. Drawing `.clear` erases (writes transparency); only `blit`
/// skips transparent source pixels. Dithered operations index the Bayer pattern by the **absolute** art
/// coordinate `artOrigin + local`, so give a canvas that will be placed at some art position that
/// position as `artOrigin` and its dithers line up with everything around it.
///
/// Shapes are pixel-art shapes, not antialiased geometry: ellipses and rounded rects are symmetric,
/// fill whole rows, and their strokes are exactly the 4-connected boundary of the matching fill (so
/// drawing a fill and then its stroke never leaves fill pixels outside the outline).
public struct PixelCanvas: Equatable, Sendable {
    public var buffer: PixelBuffer
    /// Art-space position of buffer pixel (0, 0). Only the dither phase depends on it.
    public var artOrigin: ArtPoint

    public init(width: Int, height: Int, fill: Ink = .clear, artOrigin: ArtPoint = .zero) {
        self.buffer = PixelBuffer(width: width, height: height, fill: fill.color)
        self.artOrigin = artOrigin
    }

    public init(_ buffer: PixelBuffer, artOrigin: ArtPoint = .zero) {
        self.buffer = buffer
        self.artOrigin = artOrigin
    }

    /// Starts from a rendered sprite (for adding procedural detail to hand-drawn art).
    public init(_ sprite: IndexedSprite, artOrigin: ArtPoint = .zero) {
        self.init(sprite.render(), artOrigin: artOrigin)
    }

    public var width: Int { buffer.width }
    public var height: Int { buffer.height }
    public var size: ArtSize { buffer.size }
    public var bounds: ArtRect { buffer.bounds }

    // MARK: - Pixels

    public mutating func plot(_ x: Int, _ y: Int, _ ink: Ink) {
        buffer.set(x, y, ink.color)
    }

    public mutating func plot(_ p: ArtPoint, _ ink: Ink) {
        buffer.set(p.x, p.y, ink.color)
    }

    public mutating func plot(_ points: [ArtPoint], _ ink: Ink) {
        LineRaster.plot(points, color: ink.color, into: &buffer)
    }

    /// The ink at `(x, y)`: `.clear` outside the buffer, nil for a colour that is not an Apollo ink.
    public func ink(at x: Int, _ y: Int) -> Ink? {
        let c = buffer.pixel(x, y)
        if c == .clear { return .clear }
        return Apollo.index(of: c).map { Ink(palette: $0) }
    }

    // MARK: - Rects and lines

    /// Fills the whole canvas.
    public mutating func fill(_ ink: Ink) {
        buffer.fillAll(ink.color)
    }

    public mutating func fill(_ rect: ArtRect, _ ink: Ink) {
        buffer.fill(rect, ink.color)
    }

    /// A horizontal run of `length` pixels starting at `(x, y)` (nothing when `length <= 0`).
    public mutating func hline(x: Int, y: Int, length: Int, _ ink: Ink) {
        buffer.fill(ArtRect(x, y, max(0, length), 1), ink.color)
    }

    /// A vertical run of `length` pixels starting at `(x, y)` (nothing when `length <= 0`).
    public mutating func vline(x: Int, y: Int, length: Int, _ ink: Ink) {
        buffer.fill(ArtRect(x, y, 1, max(0, length)), ink.color)
    }

    /// 1-px border just inside `rect`.
    public mutating func stroke(_ rect: ArtRect, _ ink: Ink) {
        guard !rect.isEmpty else { return }
        hline(x: rect.x, y: rect.y, length: rect.w, ink)
        hline(x: rect.x, y: rect.maxY - 1, length: rect.w, ink)
        vline(x: rect.x, y: rect.y, length: rect.h, ink)
        vline(x: rect.maxX - 1, y: rect.y, length: rect.h, ink)
    }

    /// A raised 1-px bevel just inside `rect`, lit from the top-left: the top row and left column are
    /// `light`, the bottom row and right column `dark`. The two ambiguous corners (top-right and
    /// bottom-left) take `corners` when given, otherwise `dark`; the top-left corner is always `light`.
    /// Swap the inks for a sunken bevel. On 1-px-thin rects the dark side wins.
    public mutating func bevel(_ rect: ArtRect, light: Ink, dark: Ink, corners: Ink? = nil) {
        guard !rect.isEmpty else { return }
        hline(x: rect.x, y: rect.y, length: rect.w - 1, light)
        vline(x: rect.x, y: rect.y, length: rect.h - 1, light)
        hline(x: rect.x, y: rect.maxY - 1, length: rect.w, dark)
        vline(x: rect.maxX - 1, y: rect.y, length: rect.h, dark)
        if let corners, rect.w > 1, rect.h > 1 {
            plot(rect.maxX - 1, rect.y, corners)
            plot(rect.x, rect.maxY - 1, corners)
        }
    }

    /// The segment `a`–`b` (Bresenham, both endpoints included).
    public mutating func line(from a: ArtPoint, to b: ArtPoint, _ ink: Ink) {
        LineRaster.draw(from: a, to: b, color: ink.color, into: &buffer)
    }

    /// Connected segments through `vertices`; `pixelPerfect` removes L-shaped corner doubles.
    public mutating func polyline(_ vertices: [ArtPoint], _ ink: Ink, pixelPerfect: Bool = true) {
        let pts = LineRaster.polyline(vertices)
        plot(pixelPerfect ? LineRaster.pixelPerfect(pts) : pts, ink)
    }

    // MARK: - Dither and gradients

    /// Fills `rect` with a two-ink ordered dither that is `fraction` `b` (0 = all `a`, 1 = all `b`).
    public mutating func ditherFill(_ rect: ArtRect, _ a: Ink, _ b: Ink, fraction: Double, cell: Int = 1) {
        let r = rect.intersection(bounds)
        guard !r.isEmpty else { return }
        let ca = a.color, cb = b.color
        for y in r.minY..<r.maxY {
            for x in r.minX..<r.maxX {
                let pickB = Dither.pick(x: artOrigin.x + x, y: artOrigin.y + y, fraction: fraction, cell: cell)
                buffer.pixels[y * width + x] = pickB ? cb : ca
            }
        }
    }

    /// A top-to-bottom gradient: `rect` is split into `inks.count` even bands (heights differ by at most
    /// one row), and each boundary gets a 2-px dithered transition: the last row of the upper band is
    /// 25% lower ink and the first row of the lower band 75%, staggered so they read as a soft edge.
    /// A band only gives up an edge row when it keeps at least one solid row.
    public mutating func gradientV(_ rect: ArtRect, inks: [Ink]) {
        gradient(rect, inks: inks, vertical: true)
    }

    /// Left-to-right counterpart of `gradientV(_:inks:)`.
    public mutating func gradientH(_ rect: ArtRect, inks: [Ink]) {
        gradient(rect, inks: inks, vertical: false)
    }

    private mutating func gradient(_ rect: ArtRect, inks: [Ink], vertical: Bool) {
        guard !rect.isEmpty, let firstInk = inks.first else { return }
        if inks.count == 1 { return fill(rect, firstInk) }
        let n = inks.count
        let length = vertical ? rect.h : rect.w
        // Band i covers offsets starts[i] ..< starts[i + 1] along the gradient axis.
        let starts = (0...n).map { $0 * length / n }
        func canDonate(_ band: Int) -> Bool {
            let neighbours = (band > 0 ? 1 : 0) + (band < n - 1 ? 1 : 0)
            return starts[band + 1] - starts[band] > neighbours
        }
        let clip = rect.intersection(bounds)
        guard !clip.isEmpty else { return }
        for band in 0..<n where starts[band] < starts[band + 1] {
            for t in starts[band]..<starts[band + 1] {
                let line = vertical
                    ? ArtRect(rect.x, rect.y + t, rect.w, 1).intersection(clip)
                    : ArtRect(rect.x + t, rect.y, 1, rect.h).intersection(clip)
                guard !line.isEmpty else { continue }
                // Mix with the next band on our last row, with the previous band on our first row.
                var other: Ink? = nil
                var otherIsNext = false
                if t == starts[band + 1] - 1, band < n - 1, canDonate(band) {
                    other = inks[band + 1]
                    otherIsNext = true
                } else if t == starts[band], band > 0, canDonate(band) {
                    other = inks[band - 1]
                }
                guard let other else {
                    fill(line, inks[band])
                    continue
                }
                for y in line.minY..<line.maxY {
                    for x in line.minX..<line.maxX {
                        // `along` runs with the gradient, `across` along the transition row.
                        let ax = artOrigin.x + x, ay = artOrigin.y + y
                        let along = vertical ? ay : ax, across = vertical ? ax : ay
                        // 25% dots on the upper row; the lower row's 25% holes sit two pixels over.
                        let dot = ((across + along) & 3) == (otherIsNext ? 0 : 3)
                        plot(x, y, dot ? other : inks[band])
                    }
                }
            }
        }
    }

    // MARK: - Shapes

    /// The ellipse inscribed in `rect` (integer midpoint algorithm; correct for even and odd sizes).
    public mutating func ellipseFill(_ rect: ArtRect, _ ink: Ink) {
        fillSpans(Self.ellipseSpans(w: rect.w, h: rect.h), at: rect.origin, ink)
    }

    /// The 1-px outline of `ellipseFill(rect, _)`.
    public mutating func ellipseStroke(_ rect: ArtRect, _ ink: Ink) {
        strokeSpans(Self.ellipseSpans(w: rect.w, h: rect.h), at: rect.origin, ink)
    }

    /// `rect` with pixel-art rounded corners: radius 1 cuts the corner pixel, 2 and up follow a quarter
    /// circle (`2` → insets 2,1; `3` → 3,1,1; `4` → 4,2,1,1). The radius is clamped so that straight
    /// edges stay at least 2 px long (radius 1 is still allowed on 3-px shapes).
    public mutating func roundedRectFill(_ rect: ArtRect, radius: Int, _ ink: Ink) {
        fillSpans(Self.roundedRectSpans(w: rect.w, h: rect.h, radius: radius), at: rect.origin, ink)
    }

    /// The 1-px outline of `roundedRectFill(rect, radius:, _)`.
    public mutating func roundedRectStroke(_ rect: ArtRect, radius: Int, _ ink: Ink) {
        strokeSpans(Self.roundedRectSpans(w: rect.w, h: rect.h, radius: radius), at: rect.origin, ink)
    }

    /// Fills a polygon (even-odd rule). Vertices are pixel-**corner** coordinates, like `ArtRect` edges:
    /// a pixel is filled when its centre is inside, and centres exactly on an edge belong to the shape on
    /// their right (the left-edge rule). Polygons that share an edge therefore tile with no overlap and
    /// no gap, and the polygon `(x,y) (x+w,y) (x+w,y+h) (x,y+h)` fills exactly `ArtRect(x, y, w, h)`.
    public mutating func polygonFill(_ vertices: [ArtPoint], _ ink: Ink) {
        guard vertices.count >= 3 else { return }
        let minY = max(vertices.map(\.y).min()!, 0)
        let maxY = min(vertices.map(\.y).max()!, height)
        guard minY < maxY else { return }
        let color = ink.color
        var crossings: [Int] = []
        for y in minY..<maxY {
            crossings.removeAll(keepingCapacity: true)
            // Sample the scanline at y + 1/2 (2y + 1 in doubled units); vertices sit on whole rows, so
            // the sample never passes through a vertex and every crossing is unambiguous.
            let sy2 = 2 * y + 1
            for i in vertices.indices {
                let p = vertices[i], q = vertices[(i + 1) % vertices.count]
                guard p.y != q.y else { continue }
                let (top, bottom) = p.y < q.y ? (p, q) : (q, p)
                guard 2 * top.y < sy2, sy2 < 2 * bottom.y else { continue }
                crossings.append(Self.firstPixelRightOf(top, bottom, sampleY2: sy2))
            }
            crossings.sort()
            var i = 0
            while i + 1 < crossings.count {
                let r = ArtRect(crossings[i], y, crossings[i + 1] - crossings[i], 1)
                buffer.fill(r, color)
                i += 2
            }
        }
    }

    /// For the edge `top`→`bottom` crossing the scanline at doubled height `sampleY2`, the smallest pixel
    /// column whose centre is at or right of the crossing: `ceil(X - 1/2)`, computed exactly. The result
    /// depends only on the edge, never on its direction, so neighbours sharing it agree pixel for pixel.
    private static func firstPixelRightOf(_ top: ArtPoint, _ bottom: ArtPoint, sampleY2: Int) -> Int {
        // X = top.x + (bottom.x - top.x) * (sampleY2 - 2 top.y) / (2 (bottom.y - top.y))
        // ceil(X - 1/2) = ceil((2X - 1) / 2) = ceil(num / den) with:
        let dy = bottom.y - top.y  // > 0
        let num = (2 * top.x - 1) * dy + (bottom.x - top.x) * (sampleY2 - 2 * top.y)
        let den = 2 * dy
        return num >= 0 ? (num + den - 1) / den : -((-num) / den)
    }

    // MARK: - Blits

    /// Copies `src` with its top-left at `origin`, skipping transparent pixels.
    public mutating func blit(_ src: PixelBuffer, at origin: ArtPoint) {
        buffer.blit(src, at: origin, alphaTest: true)
    }

    /// Draws `sprite` with its top-left at `origin`, skipping `.clear` inks (after `remap`).
    public mutating func blit(_ sprite: IndexedSprite, at origin: ArtPoint, remap: [Ink: Ink] = [:]) {
        let dst = ArtRect(origin.x, origin.y, sprite.w, sprite.h).intersection(bounds)
        guard !dst.isEmpty else { return }
        for y in dst.minY..<dst.maxY {
            let row = (y - origin.y) * sprite.w - origin.x
            for x in dst.minX..<dst.maxX {
                var ink = sprite.inks[row + x]
                if !remap.isEmpty, let mapped = remap[ink] { ink = mapped }
                if ink.isClear { continue }
                buffer.pixels[y * width + x] = ink.color
            }
        }
    }

    // MARK: - Spans

    private mutating func fillSpans(_ spans: [ClosedRange<Int>?], at origin: ArtPoint, _ ink: Ink) {
        for (i, span) in spans.enumerated() {
            guard let span else { continue }
            hline(x: origin.x + span.lowerBound, y: origin.y + i, length: span.count, ink)
        }
    }

    /// Plots the pixels of each span that have a 4-neighbour outside the shape.
    private mutating func strokeSpans(_ spans: [ClosedRange<Int>?], at origin: ArtPoint, _ ink: Ink) {
        for (i, span) in spans.enumerated() {
            guard let span else { continue }
            let above = i > 0 ? spans[i - 1] : nil
            let below = i + 1 < spans.count ? spans[i + 1] : nil
            // Interior pixels: not a span end, and covered by the rows above and below.
            var innerLo = span.lowerBound + 1, innerHi = span.upperBound - 1
            if let above, let below {
                innerLo = max(innerLo, above.lowerBound, below.lowerBound)
                innerHi = min(innerHi, above.upperBound, below.upperBound)
            } else {
                innerHi = innerLo - 1
            }
            let y = origin.y + i
            for x in span where !(x >= innerLo && x <= innerHi) {
                plot(origin.x + x, y, ink)
            }
        }
    }

    /// Row spans (relative to the rect origin) of the ellipse inscribed in a `w`×`h` box: Zingl's
    /// integer midpoint ellipse ("A Rasterizing Algorithm for Drawing Curves", 2012), run on the wide
    /// orientation and transposed for tall boxes so both axes get identical treatment.
    static func ellipseSpans(w: Int, h: Int) -> [ClosedRange<Int>?] {
        guard w > 0, h > 0 else { return [] }
        var lo = [Int](repeating: .max, count: h), hi = [Int](repeating: .min, count: h)
        func mark(_ x: Int, _ y: Int) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            lo[y] = min(lo[y], x)
            hi[y] = max(hi[y], x)
        }
        if w >= h {
            zinglEllipse(w: w, h: h) { x, y in mark(x, y) }
        } else {
            zinglEllipse(w: h, h: w) { x, y in mark(y, x) }
        }
        return (0..<h).map { lo[$0] <= hi[$0] ? lo[$0]...hi[$0] : nil }
    }

    /// Outline of the ellipse in the box `(0, 0)…(w-1, h-1)`; reliable for `w >= h`.
    private static func zinglEllipse(w: Int, h: Int, plot: (Int, Int) -> Void) {
        var x0 = 0, x1 = w - 1
        var a = w - 1
        let b = h - 1
        var b1 = b & 1
        var dx = 4 * (1 - a) * b * b
        var dy = 4 * (b1 + 1) * a * a
        var err = dx + dy + b1 * a * a
        var y0 = (b + 1) / 2
        var y1 = y0 - b1
        a *= 8 * a
        b1 = 8 * b * b
        repeat {
            plot(x1, y0)
            plot(x0, y0)
            plot(x0, y1)
            plot(x1, y1)
            let e2 = 2 * err
            if e2 <= dy {
                y0 += 1
                y1 -= 1
                dy += a
                err += dy
            }
            if e2 >= dx || 2 * err > dy {
                x0 += 1
                x1 -= 1
                dx += b1
                err += dx
            }
        } while x0 <= x1
        // Flat ellipses stop early; finish the tips.
        while y0 - y1 < b {
            plot(x0 - 1, y0)
            plot(x1 + 1, y0)
            y0 += 1
            plot(x0 - 1, y1)
            plot(x1 + 1, y1)
            y1 -= 1
        }
    }

    /// Row spans of a `w`×`h` rounded rect; corner insets are the quarter circle of radius `r` centred
    /// on pixel `(r, r)`: row `y < r` starts at the first `x` with `(r-x)² + (r-y)² <= r²`.
    static func roundedRectSpans(w: Int, h: Int, radius: Int) -> [ClosedRange<Int>?] {
        guard w > 0, h > 0 else { return [] }
        let m = min(w, h)
        var r = min(max(radius, 0), (m - 2) / 2)
        if radius >= 1, r < 1, m >= 3 { r = 1 }
        var insets = [Int](repeating: 0, count: r)
        for y in 0..<r {
            var x = 0
            while x < r, (r - x) * (r - x) + (r - y) * (r - y) > r * r { x += 1 }
            insets[y] = x
        }
        return (0..<h).map { y in
            let inset = y < r ? insets[y] : (y >= h - r ? insets[h - 1 - y] : 0)
            return inset...(w - 1 - inset)
        }
    }
}
