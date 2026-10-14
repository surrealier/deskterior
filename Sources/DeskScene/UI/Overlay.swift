import DeskCore
import DeskPixels
import SpriteKit

/// The monitor's full-screen cards (DESIGN §3.1 item 2, §2.2 E1), in screen px (196×108) with their buttons:
/// the first-run connect prompt, "connecting", NO SIGNAL for a folder we may not read (Open Settings / Choose
/// Folder…) and DESKTOP HIDDEN when Finder hides desktop items (Show / Keep hidden). Static frames: nothing on
/// a card animates, so it costs no wakeups.
enum ScreenCard {
    struct Rendered: Equatable {
        var image: PixelBuffer
        /// Button part names ("card.show") → screen-local rects.
        var buttons: [String: ArtRect]
    }

    /// The card for `overlay`, its text in `language` (nil: the current language).
    static func render(_ overlay: ScreenOverlay, wallpaper: PixelBuffer, font: PixelFont?, language: Language? = nil)
        -> Rendered? {
        guard let font else { return nil }
        switch overlay {
        case .connectPrompt: return connectPrompt(wallpaper, font, language)
        case .connecting: return connecting(wallpaper, font, language)
        case .noAccess: return noAccess(font, language)
        case .desktopHidden: return desktopHidden(wallpaper, font, language)
        case .none, .av: return nil
        }
    }

    /// "PRESS ⏻ TO CONNECT DESKTOP" on a panel over the dimmed wallpaper, with an arrow toward the power button.
    static func connectPrompt(_ wallpaper: PixelBuffer, _ font: PixelFont, _ language: Language? = nil) -> Rendered {
        var c = PixelCanvas(dimmed(wallpaper, steps: 2))
        let head = PixelText.shadowed(L10n.tr("PRESS", language), .neutral9, shadow: .neutral0, font: font)
        let tail = PixelText.shadowed(L10n.tr("TO CONNECT", language), .neutral9, shadow: .neutral0, font: font)
        let second = PixelText.shadowed(L10n.tr("DESKTOP", language), .neutral9, shadow: .neutral0, font: font)
        let sub = PixelText.line(L10n.tr("Shows your Desktop files here.", language), .neutral7, font: font)
        let glyph = powerGlyph(Role.ledOn)
        let gap = 4
        let firstW = head.width + gap + glyph.width + gap + tail.width
        let lineH = head.height
        let contentW = max(firstW, second.width, sub.width)
        let contentH = lineH * 2 + 2 + sub.height + 6
        let panel = clearOfMoon(ArtRect((c.width - contentW) / 2 - 8, (c.height - contentH) / 2 - 6, contentW + 16,
                                        contentH + 12), on: wallpaper)
        drawPanel(&c, panel)
        var y = panel.y + 6
        var x = (c.width - firstW) / 2
        c.blit(head, at: ArtPoint(x, y))
        x += head.width + gap
        c.blit(glyph, at: ArtPoint(x, y + (lineH - glyph.height) / 2))
        x += glyph.width + gap
        c.blit(tail, at: ArtPoint(x, y))
        y += lineH + 2
        c.blit(second, at: ArtPoint((c.width - second.width) / 2, y))
        y += lineH + 6
        c.blit(sub, at: ArtPoint((c.width - sub.width) / 2, y))
        // An arrow in the bottom-right corner pointing at the power button on the chin.
        drawArrow(&c, at: ArtPoint(c.width - 13, c.height - 12))
        return Rendered(image: c.buffer, buttons: [:])
    }

    static func connecting(_ wallpaper: PixelBuffer, _ font: PixelFont, _ language: Language? = nil) -> Rendered {
        var c = PixelCanvas(dimmed(wallpaper, steps: 1))
        let text = PixelText.shadowed(L10n.tr("CONNECTING…", language), .neutral9, shadow: .neutral0, font: font)
        let panel = ArtRect((c.width - text.width) / 2 - 6, (c.height - text.height) / 2 - 4, text.width + 12, text.height + 8)
        drawPanel(&c, panel)
        c.blit(text, at: ArtPoint(panel.x + 6, panel.y + 4))
        return Rendered(image: c.buffer, buttons: [:])
    }

    /// NO SIGNAL: the folder could not be read. Open Settings, or pick the folder (which grants access).
    static func noAccess(_ font: PixelFont, _ language: Language? = nil) -> Rendered {
        var c = PixelCanvas(MonitorArt.noSignalScreen(logo: ArtPoint(-100, -100), input: ""))
        let logo = noSignalBadge(font, language)
        let l1 = PixelText.line(L10n.tr("Can't read the Desktop folder.", language), .neutral8, font: font)
        let l2 = PixelText.line(L10n.tr("Allow access, or choose it:", language), .neutral6, font: font)
        let settings = button(L10n.tr("Open Settings", language), primary: false, font: font)
        let choose = button(L10n.tr("Choose Folder…", language), primary: true, font: font)
        let rowW = settings.width + 6 + choose.width
        let total = logo.height + 6 + l1.height + 1 + l2.height + 6 + settings.height
        var y = (c.height - total) / 2
        c.blit(logo, at: ArtPoint((c.width - logo.width) / 2, y))
        y += logo.height + 6
        c.blit(l1, at: ArtPoint((c.width - l1.width) / 2, y))
        y += l1.height + 1
        c.blit(l2, at: ArtPoint((c.width - l2.width) / 2, y))
        y += l2.height + 6
        let x0 = (c.width - rowW) / 2
        let r1 = ArtRect(x0, y, settings.width, settings.height)
        let r2 = ArtRect(r1.maxX + 6, y, choose.width, choose.height)
        c.blit(settings, at: r1.origin)
        c.blit(choose, at: r2.origin)
        return Rendered(image: c.buffer, buttons: ["card.openSettings": r1, "card.chooseFolder": r2])
    }

    /// DESKTOP HIDDEN: Finder hides desktop items; ask before mirroring them.
    static func desktopHidden(_ wallpaper: PixelBuffer, _ font: PixelFont, _ language: Language? = nil) -> Rendered {
        var c = PixelCanvas(dimmed(wallpaper, steps: 2))
        let title = PixelText.shadowed(L10n.tr("DESKTOP HIDDEN", language), .walnut5, shadow: .neutral0, font: font)
        let l1 = PixelText.line(L10n.tr("Finder hides desktop items.", language), .neutral8, font: font)
        let l2 = PixelText.line(L10n.tr("Show them on the desk anyway?", language), .neutral8, font: font)
        let show = button(L10n.tr("Show", language), primary: true, font: font)
        let keep = button(L10n.tr("Keep Hidden", language), primary: false, font: font)
        let rowW = show.width + 6 + keep.width
        let contentW = max(title.width, l1.width, l2.width, rowW)
        let contentH = title.height + 3 + l1.height + 1 + l2.height + 5 + show.height
        let panel = clearOfMoon(ArtRect((c.width - contentW) / 2 - 7, (c.height - contentH) / 2 - 5, contentW + 14,
                                        contentH + 10), on: wallpaper)
        drawPanel(&c, panel)
        var y = panel.y + 5
        c.blit(title, at: ArtPoint((c.width - title.width) / 2, y))
        y += title.height + 3
        c.blit(l1, at: ArtPoint((c.width - l1.width) / 2, y))
        y += l1.height + 1
        c.blit(l2, at: ArtPoint((c.width - l2.width) / 2, y))
        y += l2.height + 5
        let r1 = ArtRect((c.width - rowW) / 2, y, show.width, show.height)
        let r2 = ArtRect(r1.maxX + 6, y, keep.width, keep.height)
        c.blit(show, at: r1.origin)
        c.blit(keep, at: r2.origin)
        return Rendered(image: c.buffer, buttons: ["card.show": r1, "card.keepHidden": r2])
    }

    // MARK: Pieces

    // MARK: w6-polish
    /// `panel` moved so its top edge never cuts through the night wallpaper's moon, which left a sliver of it over the
    /// card like a stray mark (Errata 26): down past it when the card still fits on the glass, else up over it. Other
    /// wallpapers keep the panel where it is.
    static func clearOfMoon(_ panel: ArtRect, on wallpaper: PixelBuffer) -> ArtRect {
        let screen = wallpaper.size, moon = MonitorArt.nightMoon(in: screen)
        guard wallpaper == MonitorArt.deskOSWallpaper(sky: .night, size: screen),
              panel.minX < moon.maxX, panel.maxX > moon.minX, panel.minY > moon.minY, panel.minY < moon.maxY
        else { return panel }
        let down = moon.maxY + 1 - panel.minY
        if panel.maxY + down <= screen.h - 3 { return panel.offsetBy(0, down) }
        return panel.offsetBy(0, moon.minY - 1 - panel.minY)
    }

    /// The NO SIGNAL badge over the card's text: the monitor's own logo in English; in another language the same
    /// purple badge round the translated words (Errata 26).
    static func noSignalBadge(_ font: PixelFont, _ language: Language? = nil) -> PixelBuffer {
        let text = L10n.tr("NO SIGNAL", language)
        guard text != "NO SIGNAL" else { return MonitorArt.noSignalLogo().image }
        let words = PixelText.line(text, .neutral9, font: font)
        let ink = words.opaqueBounds()
        let w = words.width + 8, h = ink.h + 6
        var c = PixelCanvas(width: w, height: h)
        c.roundedRectFill(c.bounds, radius: 2, .purple3)
        c.roundedRectFill(c.bounds.insetBy(1, 1), radius: 1, .purple1)
        c.hline(x: 2, y: 1, length: w - 4, .purple2)
        c.blit(words, at: ArtPoint(4, 3 - ink.minY))
        return c.buffer
    }

    /// Buttons drawn as the card's default (blue) button.
    static let primaryButtons: Set<String> = ["card.show", "card.chooseFolder"]

    /// A pixel button: rim, lit top edge, face, and the label with a shadow. Pressed, the face sinks 1 px into its
    /// shadow and loses the lit edge.
    static func button(_ title: String, primary: Bool, pressed: Bool = false, font: PixelFont) -> PixelBuffer {
        let text = PixelText.shadowed(title, .neutral9, shadow: primary ? .blue1 : .neutral1, font: font)
        let w = text.width + 9, h = text.height + 4
        let d = pressed ? 1 : 0
        var c = PixelCanvas(width: w, height: h + 1)
        c.roundedRectFill(ArtRect(0, 1, w, h), radius: 2, .neutral0)
        c.roundedRectFill(ArtRect(0, d, w, h), radius: 2, .neutral0)
        let face = ArtRect(1, 1 + d, w - 2, h - 2)
        c.roundedRectFill(face, radius: 1, primary ? (pressed ? .blue2 : Role.selection) : (pressed ? .neutral3 : .neutral4))
        if !pressed { c.hline(x: face.x + 1, y: face.y, length: face.w - 2, primary ? .blue4 : .neutral5) }
        c.blit(text, at: ArtPoint(5, 2 + d))
        return c.buffer
    }

    static func drawPanel(_ c: inout PixelCanvas, _ r: ArtRect) {
        c.roundedRectFill(r.offsetBy(1, 1), radius: 3, .neutral0)
        c.roundedRectFill(r, radius: 3, .neutral4)
        c.roundedRectFill(r.insetBy(1, 1), radius: 2, .neutral1)
        c.hline(x: r.x + 3, y: r.y + 1, length: r.w - 6, .neutral3)
    }

    /// 7×7 ⏻ glyph in `ink` with a dark rim.
    static func powerGlyph(_ ink: Ink) -> PixelBuffer {
        let rows = ["...#...", ".#.#.#.", "#..#..#", "#.....#", "#.....#", ".#...#.", "..###.."]
        var c = PixelCanvas(width: 9, height: 9)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" {
                for (dx, dy) in [(0, 1), (1, 0), (1, 2), (2, 1), (1, 1)] where c.ink(at: x + dx, y + dy) == .clear {
                    c.plot(x + dx, y + dy, .neutral0)
                }
            }
        }
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" { c.plot(x + 1, y + 1, ink) }
        }
        return c.buffer
    }

    /// A small arrow pointing down-right, toward the power button.
    static func drawArrow(_ c: inout PixelCanvas, at o: ArtPoint) {
        let rows = ["##.....", "###....", ".###..#", "..###.#", "...####", "..#####", ".######"]
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" {
                c.plot(o.x + x + 1, o.y + y + 1, .neutral0)
            }
        }
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" { c.plot(o.x + x, o.y + y, Role.ledOn) }
        }
    }

    /// `b` with every palette pixel `steps` darker along its ramp (a dimmed wallpaper behind a card).
    static func dimmed(_ b: PixelBuffer, steps: Int) -> PixelBuffer {
        var out = b
        out.withUnsafeMutablePixels { px in
            for i in px.indices where px[i].a != 0 {
                guard let idx = Apollo.index(of: px[i]) else { continue }
                px[i] = Ink(palette: idx).darker(steps).color
            }
        }
        return out
    }
}

/// Short juice on the L7 fx layer (DESIGN §2.1): text pops ("BONK"), dust puffs (a removed file) and sparkles.
/// Each plays its frames once and is removed; the layer needs frames only while one plays.
final class FXLayer {
    let root = SKNode()
    private struct Effect {
        let node: SKSpriteNode
        let frames: [SKTexture]
        let size: ArtSize
        /// Canvas point of the sprite's bottom centre at the start.
        let foot: ArtPoint
        let frameTime: Double
        let life: Double
        let rise: Int
        var age: Double = 0
    }

    private var effects: [Effect] = []
    private var textures: [String: [SKTexture]] = [:]
    private let z: CGFloat
    var space: ArtSpace

    init(z: CGFloat, space: ArtSpace) {
        self.z = z
        self.space = space
    }

    var needsFrames: Bool { !effects.isEmpty }
    var count: Int { effects.count }

    /// A text pop rising 8 px over 0.7 s, standing on `foot`.
    func pop(_ pop: FXArt.Pop, at foot: ArtPoint) {
        play(FXArt.pop(pop), at: foot, frameTime: 0.7, life: 0.7, rise: 8)
    }

    /// The 5-frame dust puff at 12 fps.
    func puff(at foot: ArtPoint) {
        play(FXArt.dustPuff(), at: foot, frameTime: 1.0 / 12, life: 5.0 / 12, rise: 0)
    }

    /// A 3-frame sparkle centred on `p`.
    func sparkle(at p: ArtPoint) {
        play(FXArt.sparkle(), at: ArtPoint(p.x, p.y + 4), frameTime: 1.0 / 12, life: 3.0 / 12, rise: 0)
    }

    func step(_ dt: Double) {
        guard !effects.isEmpty else { return }
        for i in effects.indices.reversed() {
            effects[i].age += dt
            if effects[i].age >= effects[i].life {
                effects[i].node.removeFromParent()
                effects.remove(at: i)
            } else {
                place(effects[i])
            }
        }
    }

    /// Hard sleep: drop everything still playing.
    func clear() {
        for e in effects { e.node.removeFromParent() }
        effects.removeAll()
    }

    private func play(_ sprite: SpriteAsset, at foot: ArtPoint, frameTime: Double, life: Double, rise: Int) {
        let frames = textures[sprite.name] ?? sprite.frames.map(TextureFactory.texture)
        textures[sprite.name] = frames
        let node = SKSpriteNode(texture: frames[0])
        node.zPosition = z
        root.addChild(node)
        let e = Effect(node: node, frames: frames, size: sprite.size, foot: foot, frameTime: frameTime, life: life, rise: rise)
        effects.append(e)
        place(e)
    }

    private func place(_ e: Effect) {
        let frame = min(e.frames.count - 1, Int(e.age / e.frameTime))
        e.node.texture = e.frames[frame]
        let lift = Int((Double(e.rise) * e.age / e.life).rounded())
        let origin = ArtPoint(e.foot.x - e.size.w / 2, e.foot.y - e.size.h - lift)
        space.place(e.node, at: ArtRect(origin: origin, size: e.size))
    }
}
