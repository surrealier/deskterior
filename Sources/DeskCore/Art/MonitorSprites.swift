/// The monitor (DESIGN §2.2 E1–E2): body with bezel and chin controls, stand, screen states (DeskOS wallpaper,
/// off with glare, CRT power-off/on frames, NO SIGNAL card, static), LED states and page dots.
public enum MonitorArt {
    /// Neck and foot, in core px (the foot rests on the riser's top face).
    public static let standRect = ArtRect(238, 144, 52, 15)

    /// Local positions inside the 208×132 body.
    static let screenLocal = ArtRect(6, 6, 196, 108)
    static let chinTop = 114
    static let inputLocal = ArtRect(12, 118, 20, 10)
    static let powerLocal = ArtRect(184, 118, 12, 10)

    // MARK: Body

    /// The monitor body with a transparent screen hole; chin carries INPUT, the brand mark and POWER.
    public static func body() -> SpriteAsset {
        let r = CoreLayout.monitorBody
        var c = PixelCanvas(width: r.w, height: r.h)
        c.roundedRectFill(c.bounds, radius: 2, .neutral1)
        let inner = c.bounds.insetBy(1, 1)
        c.roundedRectFill(inner, radius: 1, Role.bezel)
        // Thin top face catching the window light, lit left edge.
        c.hline(x: 2, y: 0, length: r.w - 4, .neutral4)
        c.hline(x: 1, y: 1, length: r.w - 2, .neutral5)
        c.hline(x: 1, y: 2, length: r.w - 2, .neutral3)
        c.vline(x: 1, y: 2, length: chinTop - 2, .neutral3)
        c.vline(x: r.w - 2, y: 2, length: chinTop - 2, .neutral1)
        // Screen recess: shadowed top/left lip, lit bottom/right lip.
        let s = screenLocal
        c.stroke(s.insetBy(-1, -1), .neutral0)
        c.hline(x: s.x - 1, y: s.maxY, length: s.w + 2, .neutral3)
        c.vline(x: s.maxX, y: s.y - 1, length: s.h + 2, .neutral3)
        c.fill(s, .clear)

        // Chin: a slightly lighter panel with a seam.
        let chin = ArtRect(1, chinTop + 1, r.w - 2, r.h - chinTop - 2)
        c.fill(chin, Role.bezelLight)
        c.hline(x: 1, y: chinTop + 1, length: r.w - 2, .neutral4)
        c.hline(x: 2, y: r.h - 3, length: r.w - 4, Role.bezel)
        c.hline(x: 3, y: r.h - 2, length: r.w - 6, .neutral1)
        c.vline(x: 1, y: chinTop + 1, length: chin.h - 1, .neutral4)

        drawInputButton(&c, inputLocal, pressed: false)
        drawPowerButton(&c, powerLocal, pressed: false)
        let brand = "DESKTERIOR"
        let bw = Digits.measure(brand)
        Digits.draw(brand, at: ArtPoint((r.w - bw) / 2, chinTop + 7), .neutral4, into: &c)
        // LED socket.
        c.fill(ArtRect(175, 121, 4, 4), .neutral1)

        let hits: [String: ArtRect] = [
            "screen": s,
            "input": inputLocal,
            "power": CoreLayout.powerHit.offsetBy(-r.x, -r.y),
            "pageDots": CoreLayout.pageDots.offsetBy(-r.x, -r.y),
        ]
        return SpriteAsset("monitor.body", c, anchor: ArtPoint(r.w / 2, r.h), hitRects: hits)
    }

    static func drawInputButton(_ c: inout PixelCanvas, _ r: ArtRect, pressed: Bool) {
        c.roundedRectFill(r, radius: 2, .neutral1)
        let face = ArtRect(r.x + 1, r.y + 1 + (pressed ? 1 : 0), r.w - 2, r.h - 3)
        c.roundedRectFill(face, radius: 1, .neutral4)
        if !pressed { c.hline(x: face.x + 1, y: face.y, length: face.w - 2, .neutral5) }
        c.hline(x: r.x + 1, y: r.maxY - 2, length: r.w - 2, pressed ? .neutral4 : .neutral2)
        let label = "INPUT"
        Digits.draw(label, at: ArtPoint(r.x + (r.w - Digits.measure(label)) / 2, face.y + 1), .neutral7, into: &c)
    }

    /// 5×5 power glyph (⏻).
    static let powerGlyph = ["..#..", "#.#.#", "#...#", "#...#", ".###."]

    static func drawPowerButton(_ c: inout PixelCanvas, _ r: ArtRect, pressed: Bool) {
        c.roundedRectFill(r, radius: 2, .neutral1)
        let face = ArtRect(r.x + 1, r.y + 1 + (pressed ? 1 : 0), r.w - 2, r.h - 3)
        c.roundedRectFill(face, radius: 2, .neutral5)
        if !pressed { c.hline(x: face.x + 2, y: face.y, length: face.w - 4, .neutral6) }
        c.hline(x: r.x + 1, y: r.maxY - 2, length: r.w - 2, pressed ? .neutral5 : .neutral3)
        let gx = r.x + (r.w - 5) / 2, gy = face.y + 1
        for (dy, row) in powerGlyph.enumerated() {
            for (dx, ch) in row.enumerated() where ch == "#" { c.plot(gx + dx, gy + dy, .neutral8) }
        }
    }

    /// The power button alone (pressed or not), for click feedback; local to `CoreLayout.power`.
    public static func powerButton(pressed: Bool) -> SpriteAsset {
        var c = PixelCanvas(width: CoreLayout.power.w, height: CoreLayout.power.h)
        drawPowerButton(&c, c.bounds, pressed: pressed)
        return SpriteAsset(pressed ? "monitor.power.pressed" : "monitor.power", c, anchor: .zero)
    }

    /// The INPUT button alone; local to `CoreLayout.input`.
    public static func inputButton(pressed: Bool) -> SpriteAsset {
        var c = PixelCanvas(width: CoreLayout.input.w, height: CoreLayout.input.h)
        drawInputButton(&c, c.bounds, pressed: pressed)
        return SpriteAsset(pressed ? "monitor.input.pressed" : "monitor.input", c, anchor: .zero)
    }

    // MARK: Stand

    public static func stand() -> SpriteAsset {
        let r = standRect
        var c = PixelCanvas(width: r.w, height: r.h)
        let neck = CoreLayout.neck.offsetBy(-r.x, -r.y)
        // Foot: an oval plate on the riser.
        let foot = ArtRect(2, r.h - 7, r.w - 4, 6)
        c.ellipseFill(foot, .neutral1)
        c.ellipseFill(ArtRect(foot.x + 1, foot.y, foot.w - 2, foot.h - 1), .neutral3)
        c.ellipseFill(ArtRect(foot.x + 4, foot.y + 1, foot.w - 10, 2), .neutral4)
        c.hline(x: foot.x + 8, y: foot.y + 1, length: 10, .neutral5)
        // Neck.
        c.fill(ArtRect(neck.x, 0, neck.w, foot.y + 3), .neutral1)
        c.fill(ArtRect(neck.x + 1, 0, neck.w - 2, foot.y + 2), Role.bezelLight)
        c.vline(x: neck.x + 2, y: 0, length: foot.y + 1, .neutral4)
        c.vline(x: neck.x + 3, y: 0, length: foot.y, .neutral5)
        c.vline(x: neck.maxX - 3, y: 0, length: foot.y + 2, Role.bezel)
        c.hline(x: neck.x + 1, y: 0, length: neck.w - 2, .neutral1)
        // Cable hole.
        c.fill(ArtRect(neck.x + 7, 3, 6, 3), .neutral1)
        c.hline(x: neck.x + 7, y: 5, length: 6, .neutral2)
        return SpriteAsset("monitor.stand", c, anchor: ArtPoint(r.w / 2, r.h))
    }

    // MARK: Screen states

    public static var screenSize: ArtSize { CoreLayout.screen.size }

    /// Screen-local rows where the wallpaper's sky bands meet: the gutters between token rows (core y 42, 62
    /// and 82), so no seam crosses an icon.
    public static let skySeams = [24, 44, 64]

    /// The built-in "DeskOS" wallpaper: a calm banded sky over soft hills that follows the time of day (like a
    /// dynamic desktop picture). Its detail stays quieter than the icons: a deep sky hazing toward the horizon by
    /// day, small clouds, smooth ridges. No sky band uses the selection blue (`Role.selection`) or the light blue
    /// of folder icons, so highlights and folders never melt into it.
    public static func deskOSWallpaper(sky: SkyVariant = .day, size: ArtSize = CoreLayout.screen.size) -> PixelBuffer {
        var c = PixelCanvas(width: size.w, height: size.h, artOrigin: CoreLayout.screen.origin)
        let bands: [Ink], cloud: (Ink, Ink), hills: (far: Ink, near: Ink, ridge: Ink)
        switch sky {
        case .day:
            bands = [.blue2, .blue2, .neutral5, .neutral5]
            cloud = (.neutral9, .blue5)
            hills = (.green3, .green2, .green3)
        case .dusk:
            bands = [.purple1, .purple2, .purple3, .red4]
            cloud = (.red5, .purple4)
            hills = (.purple1, .purple0, .purple1)
        case .dawn:
            bands = [.blue2, .purple2, .purple5, .oak5]
            cloud = (.neutral9, .purple5)
            hills = (.blue2, .blue1, .blue2)
        case .night:
            bands = [.blue0, .blue0, .purple0, .blue1]
            cloud = (.blue2, .blue1)
            hills = (.purple0, .blue0, .blue1)
        }
        drawBands(&c, bands, seams: skySeams)
        if sky == .night {
            for i in 0..<34 {
                let x = ArtKit.noise(i, 1, seed: 91, size.w), y = ArtKit.noise(i, 2, seed: 91, size.h / 2)
                c.plot(x, y, i % 3 == 0 ? .blue5 : .neutral8)
            }
            let moon = nightMoon(in: size)
            c.ellipseFill(moon, .walnut5)
            c.ellipseFill(ArtRect(moon.x + 1, moon.y + 1, 8, 8), .neutral9)
            c.ellipseFill(ArtRect(moon.x + 5, moon.y - 2, 13, 13), .blue0)
        } else if sky != .day {
            c.ellipseFill(ArtRect(size.w / 2 - 9, size.h - 36, 18, 18), .walnut5)
            c.ellipseFill(ArtRect(size.w / 2 - 6, size.h - 33, 12, 12), .neutral9)
        }
        // Small clouds (at most 24×8).
        func puff(_ x: Int, _ y: Int, _ w: Int) {
            c.ellipseFill(ArtRect(x, y + 3, w, 5), cloud.1)
            c.ellipseFill(ArtRect(x + w / 5, y, w / 2, 6), cloud.1)
            c.ellipseFill(ArtRect(x + w / 5 + 1, y, w / 2 - 2, 3), cloud.0)
        }
        puff(18, 6, 24)
        puff(112, 2, 20)
        puff(150, 30, 16)
        // Hills: a far ridge always above the near slope, each with a lit crest.
        let h = size.h
        for x in 0..<size.w {
            let far = h - 26 - Int(5 * RoomArt.sine(Double(x) / 23) + 2 * RoomArt.sine(Double(x) / 9 + 1))
            c.vline(x: x, y: far, length: h - far, hills.far)
            let near = h - 12 - Int(5 * RoomArt.sine(Double(x) / 31 + 2))
            c.vline(x: x, y: near, length: h - near, hills.near)
            c.plot(x, near, hills.ridge)
        }
        return c.buffer
    }

    /// Fills `inks` as horizontal bands meeting at `seams` (one fewer than the inks); each change of ink is a
    /// two-row ordered dither (a quarter, then three quarters of the next ink), never a checkerboard.
    static func drawBands(_ c: inout PixelCanvas, _ inks: [Ink], seams: [Int]) {
        precondition(seams.count == inks.count - 1, "one seam between each pair of bands")
        for y in 0..<c.height {
            let k = seams.firstIndex { y < $0 } ?? seams.count
            for x in 0..<c.width {
                var ink = inks[k]
                if k < seams.count, y == seams[k] - 1, (x + 1) % 4 == 0 { ink = inks[k + 1] }
                if k > 0, y == seams[k - 1], (x + 3) % 4 == 0 { ink = inks[k - 1] }
                c.plot(x, y, ink)
            }
        }
    }

    /// Screen off: near-black glass with a diagonal glare streak.
    public static func screenOff(size: ArtSize = CoreLayout.screen.size) -> PixelBuffer {
        var c = PixelCanvas(width: size.w, height: size.h, fill: Role.screenOff)
        for i in 0..<size.h {
            let x = size.w - 40 - i
            c.hline(x: x, y: i, length: 4, Role.screenGlare)
            c.plot(x + 7, i, i % 2 == 0 ? Role.screenGlare : Role.screenOff)
        }
        for i in 0..<30 {
            c.plot(size.w - 18 - i, 4 + i, .neutral2)
        }
        return c.buffer
    }

    /// Power off (6 frames at 12 fps): squash, 4-px band, line, short line, dot, off.
    public static func powerOffFrames(from image: PixelBuffer) -> [PixelBuffer] {
        let s = image.size
        let off = screenOff(size: s)
        var frames: [PixelBuffer] = []
        var f0 = PixelCanvas(width: s.w, height: s.h, fill: Role.screenOff)
        let half = ArtKit.shifted(ArtKit.resampled(image, to: ArtSize(s.w, s.h / 2)), steps: 1)
        f0.blit(half, at: ArtPoint(0, s.h / 4))
        frames.append(f0.buffer)
        frames.append(band(s, height: 4, width: s.w))
        frames.append(band(s, height: 1, width: s.w))
        frames.append(band(s, height: 1, width: s.w * 2 / 5))
        frames.append(dot(s))
        frames.append(off)
        return frames
    }

    /// Power on (8 frames): dot, line, wide line, band, half image, overexposed full image ×2, image.
    public static func powerOnFrames(to image: PixelBuffer) -> [PixelBuffer] {
        let s = image.size
        var frames = [dot(s), band(s, height: 1, width: s.w / 3), band(s, height: 1, width: s.w), band(s, height: 6, width: s.w)]
        var half = PixelCanvas(width: s.w, height: s.h, fill: Role.screenOff)
        half.blit(ArtKit.shifted(ArtKit.resampled(image, to: ArtSize(s.w, s.h / 2)), steps: 2), at: ArtPoint(0, s.h / 4))
        frames.append(half.buffer)
        frames.append(ArtKit.shifted(image, steps: 2))
        frames.append(ArtKit.shifted(image, steps: 1))
        frames.append(image)
        return frames
    }

    private static func band(_ s: ArtSize, height: Int, width: Int) -> PixelBuffer {
        var c = PixelCanvas(width: s.w, height: s.h, fill: Role.screenOff)
        let x = (s.w - width) / 2, y = (s.h - height) / 2
        c.fill(ArtRect(x, y - 1, width, height + 2), .blue4)
        c.fill(ArtRect(x + 1, y, max(1, width - 2), height), .neutral9)
        return c.buffer
    }

    private static func dot(_ s: ArtSize) -> PixelBuffer {
        var c = PixelCanvas(width: s.w, height: s.h, fill: Role.screenOff)
        let x = s.w / 2 - 1, y = s.h / 2 - 1
        c.fill(ArtRect(x - 1, y, 4, 2), .blue4)
        c.fill(ArtRect(x, y - 1, 2, 4), .blue4)
        c.fill(ArtRect(x, y, 2, 2), .neutral9)
        return c.buffer
    }

    // MARK: w6-polish
    /// The crescent moon's disc in the night wallpaper (`deskOSWallpaper(sky: .night)`) of `size`.
    public static func nightMoon(in size: ArtSize) -> ArtRect { ArtRect(size.w - 46, 12, 14, 14) }

    /// The bouncing NO SIGNAL logo.
    public static func noSignalLogo() -> SpriteAsset {
        let text = "NO SIGNAL"
        let w = Digits.measure(text) + 8, h = 11
        var c = PixelCanvas(width: w, height: h)
        c.roundedRectFill(c.bounds, radius: 2, .purple3)
        c.roundedRectFill(c.bounds.insetBy(1, 1), radius: 1, .purple1)
        c.hline(x: 2, y: 1, length: w - 4, .purple2)
        Digits.draw(text, at: ArtPoint(4, 3), .neutral9, into: &c)
        return SpriteAsset("monitor.noSignal.logo", c, anchor: .zero)
    }

    /// The NO SIGNAL card: dark screen with the logo at `logo` (screen px; centred when nil) and the input name.
    public static func noSignalScreen(logo: ArtPoint? = nil, input: String = "AV", size: ArtSize = CoreLayout.screen.size) -> PixelBuffer {
        var c = PixelCanvas(width: size.w, height: size.h, fill: .neutral1)
        let l = noSignalLogo().image
        c.blit(l, at: logo ?? ArtPoint((size.w - l.width) / 2, (size.h - l.height) / 2))
        Digits.draw(input, at: ArtPoint(size.w - Digits.measure(input) - 4, 4), .neutral6, into: &c)
        return c.buffer
    }

    /// Two frames of static (page change).
    public static func staticFrames(size: ArtSize = CoreLayout.screen.size) -> [PixelBuffer] {
        let inks: [Ink] = [.neutral0, .neutral2, .neutral4, .neutral6, .neutral8, .neutral3]
        return (0..<2).map { f in
            var c = PixelCanvas(width: size.w, height: size.h)
            for y in 0..<size.h {
                for x in 0..<size.w {
                    c.plot(x, y, inks[ArtKit.noise(x / 2, y, seed: UInt64(f + 1) &* 31, inks.count)])
                }
            }
            return c.buffer
        }
    }

    // MARK: Chin indicators

    public enum LEDState: String, CaseIterable, Sendable { case on, amber, off }

    public static func led(_ state: LEDState) -> SpriteAsset {
        var c = PixelCanvas(width: 2, height: 2)
        let (hi, mid, lo): (Ink, Ink, Ink)
        switch state {
        case .on: (hi, mid, lo) = (.green4, Role.ledOn, .green2)
        case .amber: (hi, mid, lo) = (.walnut5, Role.ledAmber, .walnut3)
        case .off: (hi, mid, lo) = (.neutral4, .neutral3, .neutral2)
        }
        c.plot(0, 0, hi)
        c.plot(1, 0, mid)
        c.plot(0, 1, mid)
        c.plot(1, 1, lo)
        return SpriteAsset("monitor.led.\(state.rawValue)", c, anchor: .zero)
    }

    /// `count` page dots (4-px pitch) with `current` lit.
    public static func pageDots(count: Int, current: Int) -> SpriteAsset {
        let n = max(1, count)
        var c = PixelCanvas(width: n * CoreLayout.pageDotPitch - 2, height: 2)
        for i in 0..<n {
            let x = i * CoreLayout.pageDotPitch
            c.fill(ArtRect(x, 0, 2, 2), i == current ? .neutral8 : .neutral5)
            if i == current { c.plot(x, 0, .neutral9) } else { c.plot(x + 1, 1, .neutral4) }
        }
        return SpriteAsset("monitor.pageDots.\(n).\(current)", c, anchor: .zero)
    }
}
