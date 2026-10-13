/// A CPU RGBA8 image in art pixels. Row-major, **row 0 = top** (y-down), matching `ArtRect` and PNG.
///
/// This is the shared currency of the pixel pipeline: sprites, rasterizers, text and icon pixelation all
/// produce `PixelBuffer`s; DeskPixels bridges them to CGImage/PNG and DeskScene uploads them as textures.
public struct PixelBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// `width * height` pixels, row-major from the top-left. Writable only inside DeskCore (so other modules
    /// cannot break the `count == width * height` invariant); use `set`, the subscript or
    /// `withUnsafeMutablePixels` to write from elsewhere.
    public internal(set) var pixels: [RGBA8]

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
    public mutating func set(_ x: Int, _ y: Int, _ c: RGBA8) {
        if inBounds(x, y) { pixels[y * width + x] = c }
    }

    /// Fills `rect` (clipped to the buffer) with `c`.
    public mutating func fill(_ rect: ArtRect, _ c: RGBA8) {
        let r = rect.intersection(bounds)
        guard !r.isEmpty else { return }
        let w = width
        pixels.withUnsafeMutableBufferPointer { p in
            for y in r.minY..<r.maxY {
                let start = y * w + r.minX
                UnsafeMutableBufferPointer(rebasing: p[start..<(start + r.w)]).update(repeating: c)
            }
        }
    }

    public mutating func fillAll(_ c: RGBA8) {
        pixels.withUnsafeMutableBufferPointer { $0.update(repeating: c) }
    }

    /// Read-only access to the pixel storage for hot loops (row-major, `width * height` elements).
    @inlinable
    public func withUnsafePixels<R>(_ body: (UnsafeBufferPointer<RGBA8>) throws -> R) rethrows -> R {
        try pixels.withUnsafeBufferPointer(body)
    }

    /// Mutable access to the pixel storage for hot loops. The buffer's size cannot change.
    public mutating func withUnsafeMutablePixels<R>(
        _ body: (UnsafeMutableBufferPointer<RGBA8>) throws -> R
    ) rethrows -> R {
        try pixels.withUnsafeMutableBufferPointer { try body($0) }
    }

    /// The pixel storage as raw R,G,B,A bytes (`RGBA8` is exactly 4 bytes in that order).
    @inlinable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try pixels.withUnsafeBytes(body)
    }

    /// Copies `src` with its top-left at `origin`. With `alphaTest`, transparent source pixels are skipped
    /// (binary-alpha compositing); otherwise every source pixel overwrites the destination. Clipped.
    public mutating func blit(_ src: PixelBuffer, at origin: ArtPoint, alphaTest: Bool = true) {
        let dst = ArtRect(origin.x, origin.y, src.width, src.height).intersection(bounds)
        guard !dst.isEmpty else { return }
        let w = width, sw = src.width
        src.pixels.withUnsafeBufferPointer { s in
            pixels.withUnsafeMutableBufferPointer { d in
                for y in dst.minY..<dst.maxY {
                    let srow = (y - origin.y) * sw - origin.x, drow = y * w
                    for x in dst.minX..<dst.maxX {
                        let c = s[srow + x]
                        if alphaTest && c.a == 0 { continue }
                        d[drow + x] = c
                    }
                }
            }
        }
    }

    /// Like `blit`, but mirrors `src` horizontally first (for symmetric furniture drawn from one half).
    public mutating func blitFlipped(_ src: PixelBuffer, at origin: ArtPoint, alphaTest: Bool = true) {
        blit(src.flippedHorizontally(), at: origin, alphaTest: alphaTest)
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
        pixels.withUnsafeBytes { Array($0) }
    }

    /// Builds a buffer from R,G,B,A bytes (row 0 = top).
    public init(width: Int, height: Int, rgbaBytes bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4, "byte count mismatch")
        var px = [RGBA8](repeating: .clear, count: width * height)
        px.withUnsafeMutableBytes { dst in bytes.withUnsafeBytes { dst.copyMemory(from: $0) } }
        self.init(width: width, height: height, pixels: px)
    }
}
