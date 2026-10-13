/// A CPU RGBA8 image in art pixels. Row-major, **row 0 = top** (y-down), matching `ArtRect` and PNG.
///
/// This is the shared currency of the pixel pipeline: sprites, rasterizers, text and icon pixelation all
/// produce `PixelBuffer`s; DeskPixels bridges them to CGImage/PNG and DeskScene uploads them as textures.
public struct PixelBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// `width * height` pixels, row-major from the top-left.
    public var pixels: [RGBA8]

    public init(width: Int, height: Int, fill: RGBA8 = .clear) {
        precondition(width >= 0 && height >= 0, "negative PixelBuffer size")
        self.width = width
        self.height = height
        self.pixels = Array(repeating: fill, count: width * height)
    }

    public init(width: Int, height: Int, pixels: [RGBA8]) {
        precondition(pixels.count == width * height, "pixel count \(pixels.count) != \(width)x\(height)")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var size: ArtSize { ArtSize(width, height) }
    public var bounds: ArtRect { ArtRect(0, 0, width, height) }

    @inlinable
    public func inBounds(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    /// Bounds-checked access (traps when out of bounds).
    @inlinable
    public subscript(x: Int, y: Int) -> RGBA8 {
        get {
            precondition(inBounds(x, y), "PixelBuffer read out of bounds (\(x),\(y)) in \(width)x\(height)")
            return pixels[y * width + x]
        }
        set {
            precondition(inBounds(x, y), "PixelBuffer write out of bounds (\(x),\(y)) in \(width)x\(height)")
            pixels[y * width + x] = newValue
        }
    }

    /// Clipped read: returns `.clear` outside the buffer.
    @inlinable
    public func pixel(_ x: Int, _ y: Int) -> RGBA8 {
        inBounds(x, y) ? pixels[y * width + x] : .clear
    }

    /// Clipped write: silently ignores coordinates outside the buffer.
    @inlinable
    public mutating func set(_ x: Int, _ y: Int, _ c: RGBA8) {
        if inBounds(x, y) { pixels[y * width + x] = c }
    }

    /// Fills `rect` (clipped to the buffer) with `c`.
    public mutating func fill(_ rect: ArtRect, _ c: RGBA8) {
        let r = rect.intersection(bounds)
        guard !r.isEmpty else { return }
        for y in r.minY..<r.maxY {
            let row = y * width
            for x in r.minX..<r.maxX { pixels[row + x] = c }
        }
    }

    public mutating func fillAll(_ c: RGBA8) {
        for i in pixels.indices { pixels[i] = c }
    }

    /// Copies `src` with its top-left at `origin`. With `alphaTest`, transparent source pixels are skipped
    /// (binary-alpha compositing); otherwise every source pixel overwrites the destination. Clipped.
    public mutating func blit(_ src: PixelBuffer, at origin: ArtPoint, alphaTest: Bool = true) {
        let dst = ArtRect(origin.x, origin.y, src.width, src.height).intersection(bounds)
        guard !dst.isEmpty else { return }
        for y in dst.minY..<dst.maxY {
            let sy = y - origin.y
            for x in dst.minX..<dst.maxX {
                let c = src.pixels[sy * src.width + (x - origin.x)]
                if alphaTest && c.a == 0 { continue }
                pixels[y * width + x] = c
            }
        }
    }

    /// Returns the sub-image inside `rect` (clipped; empty when there is no overlap).
    public func cropped(to rect: ArtRect) -> PixelBuffer {
        let r = rect.intersection(bounds)
        guard !r.isEmpty else { return PixelBuffer(width: 0, height: 0) }
        var out = PixelBuffer(width: r.w, height: r.h)
        for y in 0..<r.h {
            for x in 0..<r.w { out.pixels[y * r.w + x] = pixels[(r.y + y) * width + (r.x + x)] }
        }
        return out
    }

    /// Integer nearest-neighbour upscale (each art pixel becomes `factor`×`factor`).
    public func scaledNearest(_ factor: Int) -> PixelBuffer {
        precondition(factor >= 1, "scale factor must be >= 1")
        if factor == 1 { return self }
        let ow = width * factor, oh = height * factor
        var out = PixelBuffer(width: ow, height: oh)
        for y in 0..<oh {
            let sy = y / factor
            for x in 0..<ow { out.pixels[y * ow + x] = pixels[sy * width + x / factor] }
        }
        return out
    }

    /// Mirrors horizontally.
    public func flippedHorizontally() -> PixelBuffer {
        var out = self
        for y in 0..<height {
            for x in 0..<width { out.pixels[y * width + x] = pixels[y * width + (width - 1 - x)] }
        }
        return out
    }

    /// Mirrors vertically (useful when handing data to y-up consumers).
    public func flippedVertically() -> PixelBuffer {
        var out = self
        for y in 0..<height {
            for x in 0..<width { out.pixels[y * width + x] = pixels[(height - 1 - y) * width + x] }
        }
        return out
    }

    /// Smallest rect containing every non-transparent pixel (`.zero` when fully transparent).
    public func opaqueBounds() -> ArtRect {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x].a != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        if maxX < 0 { return .zero }
        return ArtRect(minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// Raw bytes in R,G,B,A memory order (premultiplied-safe because alpha is binary and clear is zero).
    public var rgbaBytes: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: pixels.count * 4)
        for (i, c) in pixels.enumerated() {
            bytes[i * 4] = c.r
            bytes[i * 4 + 1] = c.g
            bytes[i * 4 + 2] = c.b
            bytes[i * 4 + 3] = c.a
        }
        return bytes
    }

    /// Builds a buffer from R,G,B,A bytes (row 0 = top).
    public init(width: Int, height: Int, rgbaBytes bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4, "byte count mismatch")
        var px = [RGBA8](repeating: .clear, count: width * height)
        for i in 0..<(width * height) {
            px[i] = RGBA8(bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3])
        }
        self.init(width: width, height: height, pixels: px)
    }
}
