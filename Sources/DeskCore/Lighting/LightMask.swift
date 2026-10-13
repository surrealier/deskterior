/// The lit pass's per-pixel light (DESIGN §1.4): one byte per canvas art px, row 0 = top; the low 3 bits are
/// the level 0…7 and bit 3 marks a warm tint. The lit pass uses `max(ambient, mask)`, so 0 means "ambient".
/// Built on the CPU and rebuilt only when a light changes.
public struct LightMask: Hashable, Sendable {
    public let size: ArtSize
    public private(set) var bytes: [UInt8]

    public static let warmBit: UInt8 = 8
    /// Width of the dithered fringe on cone and glow edges.
    public static let edge = 4

    public init(size: ArtSize) {
        self.size = size
        bytes = [UInt8](repeating: 0, count: size.area)
    }

    public static func encode(level: Int, tint: Tint) -> UInt8 {
        UInt8(min(max(level, 0), 7)) | (tint == .warm ? warmBit : 0)
    }

    public func level(_ x: Int, _ y: Int) -> Int {
        guard x >= 0, y >= 0, x < size.w, y < size.h else { return 0 }
        return Int(bytes[y * size.w + x] & 7)
    }

    public func tint(_ x: Int, _ y: Int) -> Tint {
        guard x >= 0, y >= 0, x < size.w, y < size.h else { return .cool }
        return bytes[y * size.w + x] & Self.warmBit != 0 ? .warm : .cool
    }

    /// Raises `(x, y)` to `level` (brighter wins; on a tie the earlier light keeps its tint).
    public mutating func light(_ x: Int, _ y: Int, level: Int, tint: Tint) {
        guard x >= 0, y >= 0, x < size.w, y < size.h else { return }
        let i = y * size.w + x
        if Int(bytes[i] & 7) < level { bytes[i] = Self.encode(level: level, tint: tint) }
    }

    /// An emissive rect: every pixel at `level`.
    public mutating func addRect(_ r: ArtRect, level: Int, tint: Tint) {
        let c = r.intersection(ArtRect(0, 0, size.w, size.h))
        guard !c.isEmpty else { return }
        for y in c.minY..<c.maxY {
            for x in c.minX..<c.maxX { light(x, y, level: level, tint: tint) }
        }
    }

    /// A trapezoid with horizontal top and bottom edges (top `y0` spanning `x0a…x1a`, bottom `y1` spanning
    /// `x0b…x1b`; pixel-corner coordinates). Its sides and bottom fade out over a Bayer-dithered `edge`-px
    /// fringe; the top edge is hard unless `fadeTop` (then it fades upward the same way).
    public mutating func addTrapezoid(
        top: (x0: Int, x1: Int, y: Int), bottom: (x0: Int, x1: Int, y: Int), level: Int, tint: Tint,
        edge: Int = LightMask.edge, fadeTop: Bool = false
    ) {
        guard bottom.y > top.y else { return }
        let e = Double(max(edge, 1))
        let span = Double(bottom.y - top.y)
        let yEnd = min(bottom.y + edge, size.h)
        let yStart = max(top.y - (fadeTop ? edge : 0), 0)
        for y in yStart..<max(yEnd, yStart) {
            let cy = Double(y) + 0.5
            let t = min(1, max(0, (cy - Double(top.y)) / span))
            let xl = Double(top.x0) + Double(bottom.x0 - top.x0) * t
            let xr = Double(top.x1) + Double(bottom.x1 - top.x1) * t
            let below = max(0, cy - Double(bottom.y), fadeTop ? Double(top.y) - cy : 0)
            let x0 = max(Int(xl - e) - 1, 0), x1 = min(Int(xr + e) + 1, size.w)
            guard x0 < x1 else { continue }
            for x in x0..<x1 {
                let cx = Double(x) + 0.5
                let side = max(xl - cx, cx - xr, 0)
                let d = max(side, below)
                if d <= 0 {
                    light(x, y, level: level, tint: tint)
                } else if d < e, Dither.pick(x: x, y: y, fraction: 1 - d / e) {
                    light(x, y, level: level, tint: tint)
                }
            }
        }
    }

    /// An ellipse inscribed in `r` whose rim fades over a dithered `edge`-px fringe.
    public mutating func addEllipse(_ r: ArtRect, level: Int, tint: Tint, edge: Int = LightMask.edge) {
        guard !r.isEmpty else { return }
        let cx = Double(r.x) + Double(r.w) / 2, cy = Double(r.y) + Double(r.h) / 2
        let rx = Double(r.w) / 2, ry = Double(r.h) / 2
        let e = Double(max(edge, 1))
        let x0 = max(r.x - edge, 0), x1 = min(r.maxX + edge, size.w)
        let y0 = max(r.y - edge, 0), y1 = min(r.maxY + edge, size.h)
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
                let n = (dx * dx + dy * dy).squareRoot()
                let d = (n - 1) * min(rx, ry)
                if d <= 0 || (d < e && Dither.pick(x: x, y: y, fraction: 1 - d / e)) {
                    light(x, y, level: level, tint: tint)
                }
            }
        }
    }

    /// Lights every opaque pixel of `sprite` placed at `origin` (only rows in `rows`, sprite-local, if given).
    public mutating func addSprite(_ sprite: PixelBuffer, at origin: ArtPoint, rows: Range<Int>? = nil, level: Int, tint: Tint) {
        let r = rows ?? 0..<sprite.height
        for y in r where y >= 0 && y < sprite.height {
            for x in 0..<sprite.width where sprite.pixel(x, y).a != 0 {
                light(origin.x + x, origin.y + y, level: level, tint: tint)
            }
        }
    }

    /// The mask as a palette image for goldens and review: levels as neutral steps (cool) or the walnut ramp
    /// (warm); 0 is transparent.
    public func debugImage() -> PixelBuffer {
        var out = PixelBuffer(width: size.w, height: size.h)
        let cool: [Ink] = [.clear, .neutral1, .neutral3, .neutral4, .neutral5, .neutral6, .neutral7, .neutral9]
        let warm: [Ink] = [.clear, .walnut0, .walnut1, .walnut2, .walnut3, .walnut3, .walnut4, .walnut5]
        for y in 0..<size.h {
            for x in 0..<size.w {
                let b = bytes[y * size.w + x]
                let l = Int(b & 7)
                guard l > 0 else { continue }
                out[x, y] = (b & Self.warmBit != 0 ? warm[l] : cool[l]).color
            }
        }
        return out
    }
}

/// Which room lights are on (the lamp, the monitor, the phone screen, the room light).
public struct RoomLightState: Hashable, Sendable {
    public var lampOn: Bool
    public var monitorOn: Bool
    public var phoneFaceUp: Bool
    public var roomLightOn: Bool

    public init(lampOn: Bool = true, monitorOn: Bool = true, phoneFaceUp: Bool = true, roomLightOn: Bool = true) {
        self.lampOn = lampOn
        self.monitorOn = monitorOn
        self.phoneFaceUp = phoneFaceUp
        self.roomLightOn = roomLightOn
    }

    /// The state a Lights mode implies over `self` (Lamp Only switches the room light off and the lamp on).
    public func applying(_ mode: LightsMode) -> RoomLightState {
        var s = self
        if mode == .lampOnly {
            s.roomLightOn = false
            s.lampOn = true
        }
        return s
    }
}

extension LightMask {
    /// The room's mask (DESIGN §1.4): lamp cone 7 warm, monitor glow 5 cool, phone glow 4 cool, and emissive
    /// rects at 7 for the lit screen, the LED, the window sky, the lamp bulb and (in the dark) the string lights.
    public static func room(_ layout: SceneLayout, lights: RoomLightState, time: TimeOfDay) -> LightMask {
        var m = LightMask(size: layout.canvas)
        let o = layout.coreOrigin
        func shift(_ e: (x0: Int, x1: Int, y: Int)) -> (x0: Int, x1: Int, y: Int) {
            (e.x0 + o.x, e.x1 + o.x, e.y + o.y)
        }
        m.addRect(layout.rect(WindowArt.skyRect(in: CoreLayout.window)), level: 7, tint: .cool)
        if lights.monitorOn {
            m.addEllipse(layout.rect(CoreLayout.monitorBody).insetBy(-14, -10), level: 2, tint: .cool, edge: 12)
            m.addTrapezoid(top: shift(CoreLayout.monitorGlowTop), bottom: shift(CoreLayout.monitorGlowBottom),
                           level: 3, tint: .cool, edge: 8, fadeTop: true)
            m.addRect(layout.rect(CoreLayout.screen), level: 7, tint: .cool)
        }
        if lights.lampOn {
            // A pool on the desk under the shade, spilling up the wall behind it, and a halo round the bulb.
            m.addTrapezoid(top: shift(CoreLayout.lampConeTop), bottom: shift(CoreLayout.lampConeBottom),
                           level: 7, tint: .warm)
            // What stands in the pool catches the light too: the lamp's own base, the riser's left end.
            let lamp = layout.rect(PropArt.lampRect)
            let baseRows = (CoreLayout.lampSwitch.y - PropArt.lampRect.y)..<PropArt.lampRect.h
            m.addSprite(PropArt.lamp(on: true).image, at: lamp.origin, rows: baseRows, level: 7, tint: .warm)
            m.addTrapezoid(top: (o.x + CoreLayout.riser.x, o.x + 222, o.y + CoreLayout.riser.y),
                           bottom: (o.x + CoreLayout.riser.x, o.x + 224, o.y + 168), level: 6, tint: .warm, edge: 6)
            m.addEllipse(layout.rect(PropArt.lampBulbRect).insetBy(-7, -6), level: 6, tint: .warm)
            m.addRect(layout.rect(PropArt.lampBulbRect), level: 7, tint: .warm)
        }
        m.addRect(layout.rect(CoreLayout.led), level: 7, tint: .cool)
        if lights.phoneFaceUp {
            m.addEllipse(layout.rect(CoreLayout.phone).insetBy(-7, -3), level: 4, tint: .cool, edge: 6)
            m.addRect(layout.rect(PropArt.phoneScreenRect), level: 7, tint: .cool)
        }
        if time.isDark {
            for lights in layout.decor(.stringLights) {
                for bulb in RoomArt.stringLightBulbs(in: lights.rect) {
                    m.addRect(ArtRect(bulb.x - 1, bulb.y, 3, 3), level: 7, tint: .warm)
                }
            }
        }
        return m
    }
}

extension LightMask {
    /// The lit pass on the CPU: each pixel takes `max(ambient, mask)` and the brighter source's tint, then is
    /// relit through `LightRamp`. Non-palette pixels pass through.
    public func apply(to image: PixelBuffer, ambient: AmbientLevel) -> PixelBuffer {
        precondition(image.size == size, "light mask and image differ in size")
        var out = image
        let ramp = LightRamp.shared
        out.withUnsafeMutablePixels { px in
            for i in px.indices {
                let m = bytes[i]
                let ml = Int(m & 7)
                let level = max(ambient.level, ml)
                guard level < LightRamp.maxLevel, let idx = Apollo.index(of: px[i]) else { continue }
                let tint: Tint = ml > ambient.level ? (m & Self.warmBit != 0 ? .warm : .cool) : ambient.tint
                px[i] = Apollo.colors[ramp.map(idx, level: level, tint: tint)]
            }
        }
        return out
    }
}
