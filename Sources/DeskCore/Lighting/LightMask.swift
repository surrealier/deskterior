/// The lit pass's per-pixel light (DESIGN §1.4): one byte per canvas art px, row 0 = top; the low 3 bits are
/// the level 0…7 and bits 3–4 the tint (`Tint.rawValue`: 0 cool, 1 warm, 2 screen). The lit pass uses
/// `max(ambient, mask)`, so 0 means "ambient".
/// Built on the CPU and rebuilt only when a light changes.
public struct LightMask: Hashable, Sendable {
    public let size: ArtSize
    public private(set) var bytes: [UInt8]

    public static let warmBit: UInt8 = 8
    /// Bit 4: a screen's light (`Tint.screen`).
    public static let screenBit: UInt8 = 16
    /// Width of the dithered fringe on cone and glow edges.
    public static let edge = 4
    /// Dither cell for fringes: 2×2 blocks survive scaled display modes, 1-px checkers do not (DESIGN §1.2).
    public static let cell = 2

    public init(size: ArtSize) {
        self.size = size
        bytes = [UInt8](repeating: 0, count: size.area)
    }

    public static func encode(level: Int, tint: Tint) -> UInt8 {
        UInt8(min(max(level, 0), 7)) | UInt8(tint.rawValue) << 3
    }

    /// The tint stored in a mask byte.
    public static func tint(of byte: UInt8) -> Tint {
        Tint(rawValue: Int(byte >> 3) & 3) ?? .cool
    }

    public func level(_ x: Int, _ y: Int) -> Int {
        guard x >= 0, y >= 0, x < size.w, y < size.h else { return 0 }
        return Int(bytes[y * size.w + x] & 7)
    }

    public func tint(_ x: Int, _ y: Int) -> Tint {
        guard x >= 0, y >= 0, x < size.w, y < size.h else { return .cool }
        return Self.tint(of: bytes[y * size.w + x])
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
    /// `x0b…x1b`; pixel-corner coordinates). Its sides fade out over a Bayer-dithered `edge`-px fringe and its
    /// bottom over `bottomEdge` px (default `edge`), in dither blocks of `cell` px; the top edge is hard unless
    /// `fadeTop` (then it fades upward over `edge`). Nothing outside `clip` is lit.
    public mutating func addTrapezoid(
        top: (x0: Int, x1: Int, y: Int), bottom: (x0: Int, x1: Int, y: Int), level: Int, tint: Tint,
        edge: Int = LightMask.edge, bottomEdge: Int? = nil, fadeTop: Bool = false, cell: Int = LightMask.cell,
        clip: ArtRect? = nil
    ) {
        guard bottom.y > top.y else { return }
        let area = (clip ?? ArtRect(0, 0, size.w, size.h)).intersection(ArtRect(0, 0, size.w, size.h))
        let e = Double(max(edge, 1)), eb = Double(max(bottomEdge ?? edge, 1))
        let span = Double(bottom.y - top.y)
        let yEnd = min(bottom.y + Int(eb), area.maxY)
        let yStart = max(top.y - (fadeTop ? edge : 0), area.minY)
        for y in yStart..<max(yEnd, yStart) {
            let cy = Double(y) + 0.5
            let t = min(1, max(0, (cy - Double(top.y)) / span))
            let xl = Double(top.x0) + Double(bottom.x0 - top.x0) * t
            let xr = Double(top.x1) + Double(bottom.x1 - top.x1) * t
            let below = max(0, cy - Double(bottom.y)) / eb
            let above = fadeTop ? max(0, Double(top.y) - cy) / e : 0
            let x0 = max(Int(xl - e) - 1, area.minX), x1 = min(Int(xr + e) + 1, area.maxX)
            guard x0 < x1 else { continue }
            for x in x0..<x1 {
                let cx = Double(x) + 0.5
                let f = max(max(xl - cx, cx - xr, 0) / e, below, above)
                if f <= 0 || (f < 1 && Dither.pick(x: x, y: y, fraction: 1 - f, cell: cell)) {
                    light(x, y, level: level, tint: tint)
                }
            }
        }
    }

    /// An ellipse inscribed in `r` whose rim fades over a dithered `edge`-px fringe (dither blocks of `cell` px).
    public mutating func addEllipse(_ r: ArtRect, level: Int, tint: Tint, edge: Int = LightMask.edge, cell: Int = LightMask.cell) {
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
                if d <= 0 || (d < e && Dither.pick(x: x, y: y, fraction: 1 - d / e, cell: cell)) {
                    light(x, y, level: level, tint: tint)
                }
            }
        }
    }

    /// A pool of light whose level falls off with the distance from the centre of the ellipse inscribed in `r`
    /// (`n` = 1 on its rim): `stops` give the level at increasing `n`, linear between them. A fractional level is
    /// Bayer-dithered (blocks of `cell` px) between the whole levels on either side, so the falloff reads as bands
    /// with dithered seams while every pixel keeps a whole level. Nothing is lit beyond the last stop, outside
    /// `clip`, nor where the level comes out at 1 or less (the room is never darker than that).
    public mutating func addFalloff(ellipse r: ArtRect, stops: [(n: Double, level: Double)], tint: Tint,
                                    cell: Int = LightMask.cell, clip: ArtRect? = nil) {
        guard !r.isEmpty, let first = stops.first, let last = stops.last else { return }
        let cx = Double(r.x) + Double(r.w) / 2, cy = Double(r.y) + Double(r.h) / 2
        let rx = Double(r.w) / 2, ry = Double(r.h) / 2
        let area = (clip ?? ArtRect(0, 0, size.w, size.h)).intersection(ArtRect(0, 0, size.w, size.h))
        let x0 = max(Int((cx - rx * last.n).rounded(.down)) - 1, area.minX)
        let x1 = min(Int((cx + rx * last.n).rounded(.up)) + 1, area.maxX)
        let y0 = max(Int((cy - ry * last.n).rounded(.down)) - 1, area.minY)
        let y1 = min(Int((cy + ry * last.n).rounded(.up)) + 1, area.maxY)
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
                let n = (dx * dx + dy * dy).squareRoot()
                guard n <= last.n else { continue }
                var v = first.level
                if n > first.n, let k = stops.firstIndex(where: { $0.n >= n }) {
                    let (a, b) = (stops[k - 1], stops[k])
                    v = a.level + (b.level - a.level) * (n - a.n) / max(b.n - a.n, 1e-9)
                }
                lightDithered(x, y, level: v, tint: tint, cell: cell)
            }
        }
    }

    /// Lights `(x, y)` at `floor(level)`, or one level up where the Bayer threshold falls under the fraction; levels
    /// of 1 or less light nothing.
    private mutating func lightDithered(_ x: Int, _ y: Int, level v: Double, tint: Tint, cell: Int) {
        var whole = Int(v.rounded(.down))
        if Dither.pick(x: x, y: y, fraction: v - Double(whole), cell: cell) { whole += 1 }
        if whole > 1 { light(x, y, level: min(whole, LightRamp.maxLevel), tint: tint) }
    }

    /// Lights each point.
    public mutating func addPoints(_ points: [ArtPoint], level: Int, tint: Tint) {
        for p in points { light(p.x, p.y, level: level, tint: tint) }
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

    /// The mask as a palette image for goldens and review: levels as neutral steps (cool), the walnut ramp
    /// (warm) or the blue ramp (screen); 0 is transparent.
    public func debugImage() -> PixelBuffer {
        var out = PixelBuffer(width: size.w, height: size.h)
        let cool: [Ink] = [.clear, .neutral1, .neutral3, .neutral4, .neutral5, .neutral6, .neutral7, .neutral9]
        let warm: [Ink] = [.clear, .walnut0, .walnut1, .walnut2, .walnut3, .walnut3, .walnut4, .walnut5]
        let screen: [Ink] = [.clear, .blue0, .blue1, .blue2, .blue3, .blue4, .blue5, .neutral9]
        for y in 0..<size.h {
            for x in 0..<size.w {
                let b = bytes[y * size.w + x]
                let l = Int(b & 7)
                guard l > 0 else { continue }
                switch Self.tint(of: b) {
                case .cool: out[x, y] = cool[l].color
                case .warm: out[x, y] = warm[l].color
                case .screen: out[x, y] = screen[l].color
                }
            }
        }
        return out
    }
}

/// Which room lights are on (the lamp, the monitor, the phone screen, the room light).
public struct RoomLightState: Hashable, Sendable {
    public var lampOn: Bool
    /// The monitor's glass is lit (on, or mid power transition: the CRT collapse and bloom glow on the glass).
    public var monitorOn: Bool
    /// The monitor casts its glow on the wall and desk: the display is on and not collapsing (E1, M10).
    public var monitorGlows: Bool
    public var phoneFaceUp: Bool
    public var roomLightOn: Bool
    // MARK: tidy and memos (0.3.0)
    /// The desk partition is out (the lamp washes its left wing; Erratum 31).
    public var partitionOut = true
    /// The partition's clip light is out and on.
    public var clipLightOn = false

    public init(lampOn: Bool = true, monitorOn: Bool = true, phoneFaceUp: Bool = true, roomLightOn: Bool = true,
                monitorGlows: Bool? = nil) {
        self.lampOn = lampOn
        self.monitorOn = monitorOn
        self.monitorGlows = monitorGlows ?? monitorOn
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
    /// The room's mask (DESIGN §1.4): emissive glass, screen, LED and bulbs at 7; when the room is dark enough
    /// for it (ambient 5 or less) the lamp's warm pool and halo; the monitor's glow on the desk and on the wall and
    /// the phone's glow (`screenGlowTint`); the pendant and the string lights after dark.
    public static func room(_ layout: SceneLayout, lights: RoomLightState, time: TimeOfDay) -> LightMask {
        var m = LightMask(size: layout.canvas)
        let glow = screenGlowTint(time)
        // Only the glass glows: the mullion and the blind cord stay at the room's level.
        let win = layout.rect(CoreLayout.window)
        m.addPoints(WindowArt.skyPixels().map { $0 + win.origin }, level: 7, tint: .cool)
        if lights.monitorOn && lights.monitorGlows {
            m.addEllipse(layout.rect(CoreLayout.monitorBody).insetBy(-14, -10), level: 2, tint: glow, edge: 12)
            // On the desk in front of the riser: brightest under the middle of the screen, stepping down over the
            // keyboard and toward the riser's ends, within its width (above the riser's foot it would be hidden
            // behind the riser).
            let riser = layout.rect(CoreLayout.riser)
            let reach = CoreLayout.monitorGlowFade + 14
            let pool = ArtRect(riser.x + 8, riser.maxY - reach, riser.w - 16, 2 * reach)
            m.addFalloff(ellipse: pool, stops: Self.monitorGlowFalloff, tint: glow,
                         clip: ArtRect(0, riser.maxY, layout.canvas.w, layout.canvas.h - riser.maxY))
        }
        if lights.monitorOn { m.addRect(layout.rect(CoreLayout.screen), level: 7, tint: .cool) }
        if lights.lampOn {
            if RoomArt.lampGlows(time) {
                // A pool under the shade: a bright core and a ring, then bands that step down into the dark and
                // spill onto the apron and the chair back; the lamp's own base and the riser's end catch it too.
                m.addFalloff(ellipse: layout.rect(CoreLayout.lampPool), stops: Self.lampPoolFalloff, tint: .warm)
                let lamp = layout.rect(PropArt.lampRect)
                let baseRows = (CoreLayout.lampSwitch.y - PropArt.lampRect.y)..<PropArt.lampRect.h
                m.addSprite(PropArt.lamp(on: true).image, at: lamp.origin, rows: baseRows, level: 7, tint: .warm)
                let riser = layout.rect(CoreLayout.riser)
                m.addTrapezoid(top: (riser.x, riser.x + 4, riser.y), bottom: (riser.x, riser.x + 8, riser.maxY),
                               level: 6, tint: .warm, edge: 8, clip: riser)
                m.addPoints(RoomArt.lampHaloPixels(layout).map(\.point), level: 7, tint: .warm)
            }
            m.addRect(layout.rect(PropArt.lampBulbRect), level: 7, tint: .warm)
        }
        m.addRect(layout.rect(CoreLayout.led), level: 7, tint: .cool)
        if lights.phoneFaceUp {
            m.addFalloff(ellipse: layout.rect(CoreLayout.phone).insetBy(-7, -3), stops: Self.phoneGlowFalloff, tint: glow)
            m.addRect(layout.rect(PropArt.phoneScreenRect), level: 7, tint: .cool)
        }
        if time.isDark && lights.roomLightOn {
            for p in layout.decor(.pendant) {
                let bulb = DecorArt.pendantBulb(in: p.rect.size).offsetBy(p.rect.x, p.rect.y)
                m.addEllipse(bulb.insetBy(-10, -6), level: 7, tint: .warm, edge: 6)
            }
            m.addCeilingLamps(layout)
        }
        if time.isDark, RoomArt.stringLightsLit(time) {
            for d in layout.decor(.stringLights) {
                m.addPoints(RoomArt.stringLightGlass(in: d.rect) + RoomArt.stringLightHalo(in: d.rect).map(\.point),
                            level: 7, tint: .warm)
            }
        }
        return m
    }
}

extension LightMask {
    /// The tint of the monitor's and phone's glows: screen light (oak greys) once the room is dark enough that
    /// tokens need a light to be seen (`DarkHit`), where the screens are a main light; at dusk and dawn moonlight's
    /// `cool`, a level or two over the ambient, so the glow does not stain the still-tan desk grey.
    public static func screenGlowTint(_ time: TimeOfDay) -> Tint {
        time.ambientLevel < DarkHit.minimumLevel ? .screen : .cool
    }

    /// The lamp's pool (`CoreLayout.lampPool`, `n` = 1 on its rim, Errata 8): a level-7 core and a level-6 ring
    /// inside the rim, then bands at 5, 4, 3 and 2, each held a little and dithered into the next.
    public static let lampPoolFalloff: [(n: Double, level: Double)] = [
        (0.48, 7), (0.6, 6), (0.82, 6), (0.92, 5), (1.0, 5), (1.08, 4), (1.13, 4), (1.2, 3), (1.25, 3), (1.33, 2),
        (1.37, 2), (1.46, 1),
    ]
    /// The monitor's glow on the desk (an ellipse centred on the riser's foot, its lower half showing): level 5
    /// under the screen's middle, stepping down to 2 (Errata 8's level-5 band, softened; screen light, Errata 15).
    public static let monitorGlowFalloff: [(n: Double, level: Double)] = [
        (0.5, 5), (0.62, 4), (0.74, 4), (0.84, 3), (0.92, 3), (1.02, 2), (1.08, 2), (1.16, 1),
    ]
    /// A face-up phone's glow: level 5 round the stand, stepping down to 2.
    public static let phoneGlowFalloff: [(n: Double, level: Double)] = [
        (0.7, 5), (0.82, 4), (0.94, 4), (1.04, 3), (1.12, 3), (1.22, 2), (1.3, 2), (1.38, 1),
    ]

    /// The level the lit pass gives `(x, y)` under `ambient`: the mask's, or the ambient where that is brighter.
    public func effectiveLevel(_ x: Int, _ y: Int, ambient: Int) -> Int {
        max(ambient, level(x, y))
    }

    /// The share (0…1) of `r`'s on-canvas pixels lit to at least `minimum` under `ambient` (0 when `r` is off the
    /// canvas).
    public func litFraction(_ r: ArtRect, atLeast minimum: Int, ambient: Int) -> Double {
        let c = r.intersection(ArtRect(0, 0, size.w, size.h))
        guard !c.isEmpty else { return 0 }
        if ambient >= minimum { return 1 }
        var lit = 0
        for y in c.minY..<c.maxY {
            for x in c.minX..<c.maxX where Int(bytes[y * size.w + x] & 7) >= minimum { lit += 1 }
        }
        return Double(lit) / Double(c.w * c.h)
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
                let tint: Tint = ml > ambient.level ? Self.tint(of: m) : ambient.tint
                px[i] = Apollo.colors[ramp.map(idx, level: level, tint: tint)]
            }
        }
        return out
    }
}
