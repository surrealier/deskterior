/// One piece of art as the scene uses it: one or more frames of the same size, a placement anchor, named hit
/// rects, and an alpha hit mask (DESIGN §2: pixel-precise hit-testing).
public struct SpriteAsset: Equatable, Sendable, CustomStringConvertible {
    public let name: String
    /// Every frame has the size of `frames[0]`.
    public let frames: [PixelBuffer]
    /// The placement point in sprite px (e.g. where the object stands on the desk or floor).
    public let anchor: ArtPoint
    /// Named sub-rects in sprite px (buttons, handles, mouths).
    public let hitRects: [String: ArtRect]

    public init(_ name: String, frames: [PixelBuffer], anchor: ArtPoint? = nil, hitRects: [String: ArtRect] = [:]) {
        precondition(!frames.isEmpty, "SpriteAsset \(name) has no frames")
        let size = frames[0].size
        precondition(frames.allSatisfy { $0.size == size }, "SpriteAsset \(name): frames differ in size")
        self.name = name
        self.frames = frames
        self.anchor = anchor ?? ArtPoint(size.w / 2, size.h)
        self.hitRects = hitRects
    }

    public init(_ name: String, _ image: PixelBuffer, anchor: ArtPoint? = nil, hitRects: [String: ArtRect] = [:]) {
        self.init(name, frames: [image], anchor: anchor, hitRects: hitRects)
    }

    public init(_ name: String, _ canvas: PixelCanvas, anchor: ArtPoint? = nil, hitRects: [String: ArtRect] = [:]) {
        self.init(name, frames: [canvas.buffer], anchor: anchor, hitRects: hitRects)
    }

    public var image: PixelBuffer { frames[0] }
    public var size: ArtSize { frames[0].size }
    public var frameCount: Int { frames.count }

    /// Alpha hit test in sprite px.
    public func hits(_ p: ArtPoint, frame: Int = 0) -> Bool {
        frames[min(max(frame, 0), frames.count - 1)].pixel(p.x, p.y).a != 0
    }

    /// The first named hit rect containing `p` (names sorted, so the answer is stable).
    public func part(at p: ArtPoint) -> String? {
        hitRects.keys.sorted().first { hitRects[$0]!.contains(p) }
    }

    /// The same frames under another name.
    public func renamed(_ newName: String) -> SpriteAsset {
        SpriteAsset(newName, frames: frames, anchor: anchor, hitRects: hitRects)
    }

    public var description: String { "\(name) \(size) ×\(frames.count)" }
}

// MARK: - Shared authoring helpers

/// Small helpers shared by the art files.
enum ArtKit {
    /// A 1-px outline around the opaque pixels of `b` (4-connected), in a buffer 1 px larger on every side.
    static func outline(_ b: PixelBuffer, _ ink: Ink) -> PixelBuffer {
        var out = PixelBuffer(width: b.width + 2, height: b.height + 2)
        let c = ink.color
        for y in -1...b.height {
            for x in -1...b.width where b.pixel(x, y).a == 0 {
                if b.pixel(x - 1, y).a != 0 || b.pixel(x + 1, y).a != 0 || b.pixel(x, y - 1).a != 0
                    || b.pixel(x, y + 1).a != 0 {
                    out[x + 1, y + 1] = c
                }
            }
        }
        return out
    }

    /// Replaces each opaque pixel by its ink `steps` lighter (negative: darker) along its ramp.
    static func shifted(_ b: PixelBuffer, steps: Int) -> PixelBuffer {
        var out = b
        out.withUnsafeMutablePixels { px in
            for i in px.indices where px[i].a != 0 {
                guard let idx = Apollo.index(of: px[i]) else { continue }
                let ink = Ink(palette: idx)
                px[i] = (steps >= 0 ? ink.lighter(steps) : ink.darker(-steps)).color
            }
        }
        return out
    }

    /// Recolours every opaque pixel with `map` (inks missing from the map keep their colour).
    static func remapped(_ b: PixelBuffer, _ map: [Ink: Ink]) -> PixelBuffer {
        var out = b
        out.withUnsafeMutablePixels { px in
            for i in px.indices where px[i].a != 0 {
                guard let idx = Apollo.index(of: px[i]), let to = map[Ink(palette: idx)] else { continue }
                px[i] = to.color
            }
        }
        return out
    }

    /// `b` with every opaque pixel painted `ink` (a silhouette).
    static func silhouette(_ b: PixelBuffer, _ ink: Ink) -> PixelBuffer {
        var out = b
        let c = ink.color
        out.withUnsafeMutablePixels { px in
            for i in px.indices where px[i].a != 0 { px[i] = c }
        }
        return out
    }

    /// Nearest-neighbour resample to `size` (for squash frames and CRT squeezes).
    static func resampled(_ b: PixelBuffer, to size: ArtSize) -> PixelBuffer {
        var out = PixelBuffer(width: max(0, size.w), height: max(0, size.h))
        guard size.w > 0, size.h > 0, b.width > 0, b.height > 0 else { return out }
        for y in 0..<size.h {
            let sy = min(b.height - 1, (2 * y + 1) * b.height / (2 * size.h))
            for x in 0..<size.w {
                let sx = min(b.width - 1, (2 * x + 1) * b.width / (2 * size.w))
                out[x, y] = b[sx, sy]
            }
        }
        return out
    }

    /// Deterministic hash noise in 0..<n for a coordinate and seed.
    static func noise(_ x: Int, _ y: Int, seed: UInt64 = 0, _ n: Int) -> Int {
        let key = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9 ^ UInt64(bitPattern: Int64(y)) &* 0x85EB_CA6B ^ seed
        return Int(SplitMix64.mix(key) % UInt64(max(n, 1)))
    }

    /// A soft 2-tone drop shadow: `ink` wherever `b` is opaque, shifted by `(dx, dy)`, clipped to
    /// `canvas` pixels that pass `onto` (e.g. only on the desk colour).
    static func castShadow(
        of b: PixelBuffer, at origin: ArtPoint, offset: ArtPoint, ink: Ink, into canvas: inout PixelCanvas,
        where onto: (Ink) -> Bool
    ) {
        for y in 0..<b.height {
            for x in 0..<b.width where b.pixel(x, y).a != 0 {
                let tx = origin.x + x + offset.x, ty = origin.y + y + offset.y
                guard let under = canvas.ink(at: tx, ty), onto(under) else { continue }
                canvas.plot(tx, ty, ink)
            }
        }
    }
}

extension PixelBuffer {
    /// A 1-px outline around this buffer's opaque pixels, in a buffer 1 px larger on every side (hover rings).
    public func outlined(_ ink: Ink) -> PixelBuffer {
        ArtKit.outline(self, ink)
    }
}
