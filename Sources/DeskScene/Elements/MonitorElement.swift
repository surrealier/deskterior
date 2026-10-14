import DeskCore
import DeskPixels
import SpriteKit

/// The monitor and its power button (DESIGN §2.2 E1–E2): ⏻ (zero latency; on the first-run prompt it connects
/// the desktop), INPUT (HDMI 1…n, AV, HDMI 1; inert while off), page dots (one per page in use; the dot of a page
/// new files landed on blinks), the LED and "+N" badge, the CRT collapse and bloom, the static and OSD after an
/// input change, the AV logo (≤ 10 s, restarted by hovering) and the full-screen cards (connect prompt,
/// connecting, NO SIGNAL, DESKTOP HIDDEN with their buttons, which press in). It owns the glass for gestures:
/// empty-screen clicks clear the selection, drags draw a marquee, scrolls change page. The monitor's static
/// sprites stay in the room's `PlacedElement`, which this element uses for alpha hit tests; everything that
/// changes is drawn here, over them. The visible state comes from `MonitorMachine`.
public final class MonitorElement: DeskElement {
    public let id = "monitor"
    public let root = SKNode()
    unowned let context: SceneContext
    let screen: ScreenElement
    /// The room's monitor sprites (body, stand, screen, LED, dots).
    weak var placed: PlacedElement?
    public private(set) var machine: MonitorMachine?
    private(set) var state: DeskState?

    private let cover = SKSpriteNode()
    private let osdNode = SKSpriteNode()
    private let ledNode = SKSpriteNode()
    private let dotsNode = SKSpriteNode()
    private let badgeNode = SKSpriteNode()
    private let pressedNode = SKSpriteNode()
    private let sparkleNode = SKSpriteNode()
    /// The card currently shown and its buttons (screen px).
    private(set) var card: ScreenCard.Rendered?
    private var cardKey: (ScreenOverlay, SkyVariant)?
    private var crtOff: [PixelBuffer] = []
    private var crtOn: [PixelBuffer] = []
    /// Reduce Motion's fade in place of the CRT collapse or bloom: its frames and how long it has run.
    private var fade: (frames: [PixelBuffer], t: Double)?
    private(set) var pressedPart: String?
    private var shownCover: String?
    private var shownOSD: String?
    private var shownLED: MonitorArt.LEDState?
    private var shownDots: String?
    private var shownBadge: String?
    private var scrollAccum: SIMD2<Float> = .zero
    private var scrollIdle: Double = 0
    private var scrollLocked = false
    /// Page dots blinking for new files that landed there, and for how long so far.
    private var dotBlink: (pages: Set<Int>, t: Double)?
    private lazy var staticFrames = MonitorArt.staticFrames()

    /// Scroll distance (art px) that flips one page.
    static let pageScroll: Float = 24
    /// New files on another page: its dot blinks three times.
    static let dotBlinkDuration = 1.2
    static let dotBlinkPeriod = 0.4

    init(context: SceneContext, screen: ScreenElement) {
        self.context = context
        self.screen = screen
        for n in [cover, osdNode, ledNode, dotsNode, badgeNode, pressedNode, sparkleNode] {
            n.isHidden = true
            root.addChild(n)
        }
        screen.monitor = self
    }

    // MARK: State

    public func layout(_ layout: SceneLayout) {
        refresh(force: true)
    }

    public func apply(_ s: DeskState) {
        let before = machine?.phase
        if machine == nil {
            machine = MonitorMachine(s)
        } else {
            machine!.sync(s)
        }
        state = s
        if before == .on || before == .poweringOn, machine?.phase == .poweringOff {
            crtOff = MonitorArt.powerOffFrames(from: picture(withTokens: true))
        }
        if before == .off || before == .poweringOff, machine?.phase == .poweringOn {
            crtOn = MonitorArt.powerOnFrames(to: picture(withTokens: false))
        }
        followReduceMotion()  // MARK: harden
        // Reduce Motion: no CRT collapse or bloom; the machine is off or on at once and the glass fades (M10).
        if context.reduceMotion, let phase = machine?.phase, phase == .poweringOff || phase == .poweringOn {
            let image = picture(withTokens: phase == .poweringOff)
            fade = (MonitorArt.fadeFrames(image, poweringOn: phase == .poweringOn), 0)
            machine?.settle()
        }
        refresh()
    }

    /// The screen glows (lit pass): on, or mid-transition (a Reduce Motion fade included).
    var isEmissive: Bool { fade != nil || (machine.map { $0.phase != .off } ?? true) }
    /// The screen lights the wall and desk: on or blooming, never while it collapses (M10).
    var glows: Bool { machine.map { $0.phase == .on || $0.phase == .poweringOn } ?? true }

    /// The full picture: wallpaper, then the card or the tokens.
    private func picture(withTokens: Bool) -> PixelBuffer {
        var c = PixelCanvas(MonitorArt.deskOSWallpaper(sky: context.sky))
        guard let s = state else { return c.buffer }
        switch ScreenOverlay.of(s) {
        case .none:
            if withTokens, let image = screen.image { c.blit(image, at: .zero) }
        case .av:
            return MonitorArt.noSignalScreen(logo: machine?.logo.position)
        case let overlay:
            if let card = ScreenCard.render(overlay, wallpaper: c.buffer, font: context.font) { return card.image }
        }
        return c.buffer
    }

    /// Re-renders what changed; `force` after a layout change.
    private func refresh(force: Bool = false) {
        guard let m = machine, let s = state else { return }
        let space = context.space, layout = context.layout
        let glass = layout.rect(CoreLayout.screen)
        let base = context.placementZ("monitor.screen")
        let top = context.placementZ("monitor.pageDots") + 0.5
        screen.setVisibility(showsTokens: m.showsTokens, rowsShown: m.rowsShown)
        screen.render()

        // The cover: a CRT frame, static, the AV card or a full-screen card.
        var coverKey: String?
        var coverImage: (() -> PixelBuffer)?
        if let f = fade {
            let i = min(f.frames.count - 1, Int((f.t + 1e-9) / MonitorMachine.crtFrameTime))
            coverKey = "fade\(i)"
            coverImage = { f.frames[i] }
        } else if let crt = m.crtFrame {
            switch crt {
            case let .off(i) where i < crtOff.count:
                coverKey = "off\(i)"
                coverImage = { self.crtOff[i] }
            case let .on(i) where i < crtOn.count:
                coverKey = "on\(i)"
                coverImage = { self.crtOn[i] }
            default:
                break
            }
        } else if m.showsPicture {
            if let f = m.staticFrame {
                coverKey = "static\(f)"
                coverImage = { self.staticFrames[f] }
            } else if m.overlay == .av {
                // While the green OSD says "AV", the screen's own grey "AV" stays off (no stray pixels under it).
                let p = m.logo.position, input = m.osdText == nil ? "AV" : ""
                coverKey = "av\(p.x),\(p.y),\(input)"
                coverImage = { MonitorArt.noSignalScreen(logo: p, input: input) }
            } else if m.overlay != .none {
                let sky = context.sky
                if card == nil || cardKey?.0 != m.overlay || cardKey?.1 != sky || force {
                    card = ScreenCard.render(m.overlay, wallpaper: MonitorArt.deskOSWallpaper(sky: sky), font: context.font)
                    cardKey = (m.overlay, sky)
                }
                if let card {
                    coverKey = "card.\(m.overlay.rawValue).\(sky.rawValue)"
                    coverImage = { card.image }
                }
            }
        }
        if m.overlay == .none || !m.showsPicture { card = m.overlay == .none ? nil : card }
        if coverKey != shownCover || force {
            shownCover = coverKey
            if let coverImage {
                cover.texture = TextureFactory.texture(coverImage())
                space.place(cover, at: glass)
                cover.zPosition = base + 0.3
                cover.isHidden = false
            } else {
                cover.isHidden = true
            }
        }

        // The OSD, top right of the glass.
        let osd = m.showsPicture ? m.osdText : nil
        if osd != shownOSD || force {
            shownOSD = osd
            if let osd, let font = context.font {
                let text = PixelText.shadowed(osd, .green4, shadow: .neutral0, font: font)
                var c = PixelCanvas(width: text.width + 6, height: text.height + 4)
                c.roundedRectFill(c.bounds, radius: 1, .neutral1)
                c.blit(text, at: ArtPoint(3, 2))
                osdNode.texture = TextureFactory.texture(c.buffer)
                space.place(osdNode, at: ArtRect(glass.maxX - c.width - 4, glass.minY + 4, c.width, c.height))
                osdNode.zPosition = base + 0.4
                osdNode.isHidden = false
            } else {
                osdNode.isHidden = true
            }
        }

        // Sparkle when the AV logo hits a corner exactly.
        if m.overlay == .av, m.showsPicture, m.logo.sparkle > 0 {
            let p = m.logo.position
            let frames = FXArt.sparkle().frames
            let i = min(frames.count - 1, m.logo.sparkleFrame ?? 0)
            sparkleNode.texture = TextureFactory.texture(frames[i])
            let corner = ArtPoint(glass.x + p.x + (p.x == 0 ? 0 : m.logo.size.w) - 3, glass.y + p.y + (p.y == 0 ? 0 : m.logo.size.h) - 3)
            space.place(sparkleNode, at: ArtRect(origin: corner, size: frames[i].size))
            sparkleNode.zPosition = base + 0.45
            sparkleNode.isHidden = false
        } else {
            sparkleNode.isHidden = true
        }

        // LED, page dots, badge on the chin.
        if m.led != shownLED || force {
            shownLED = m.led
            ledNode.texture = TextureFactory.texture(MonitorArt.led(m.led).image)
            space.place(ledNode, at: layout.rect(CoreLayout.led))
            ledNode.zPosition = top
            ledNode.isHidden = false
        }
        let pages = min(8, s.pageCount())
        let current = m.phase == .on || m.phase == .poweringOn ? (s.monitor.av ? -1 : s.monitor.page) : -1
        let blinking = dotBlink.flatMap { b in Int(b.t / (Self.dotBlinkPeriod / 2)) % 2 == 0 ? b.pages.filter { $0 < pages } : nil } ?? []
        let dotsKey = "\(pages).\(current).\(blinking.sorted())"
        if dotsKey != shownDots || force {
            shownDots = dotsKey
            var dots = MonitorArt.pageDots(count: pages, current: current).image
            for page in blinking {
                let lit = MonitorArt.pageDots(count: pages, current: page).image
                let r = ArtRect(page * CoreLayout.pageDotPitch, 0, 2, 2)
                dots.blit(lit.cropped(to: r), at: r.origin)
            }
            dotsNode.texture = TextureFactory.texture(dots)
            space.place(dotsNode, at: ArtRect(origin: layout.point(CoreLayout.pageDots.origin), size: dots.size))
            dotsNode.zPosition = top
            dotsNode.isHidden = false
        }
        if m.badge != shownBadge || force {
            shownBadge = m.badge
            if let badge = m.badge {
                let image = Digits.badge(badge, fill: Role.ledAmber, ink: .neutral0, rim: .walnut2)
                let led = layout.rect(CoreLayout.led)
                badgeNode.texture = TextureFactory.texture(image)
                space.place(badgeNode, at: ArtRect(led.x - image.width - 4, led.midY - image.height / 2 - 1, image.width, image.height))
                badgeNode.zPosition = top
                badgeNode.isHidden = false
            } else {
                badgeNode.isHidden = true
            }
        }
    }

    // MARK: Hit testing

    /// Card buttons in canvas px (only while a card shows).
    public var cardButtons: [String: ArtRect] {
        guard let card, let m = machine, m.showsPicture, m.overlay != .none, m.overlay != .av, m.staticFrame == nil else {
            return [:]
        }
        let glass = context.layout.rect(CoreLayout.screen)
        return card.buttons.mapValues { $0.offsetBy(glass.x, glass.y) }
    }

    public func hitTest(_ p: ArtPoint) -> Hit? {
        if let (name, r) = cardButtons.first(where: { $0.value.contains(p) }) {
            return Hit(element: id, part: name, rect: r)
        }
        guard let h = placed?.hitTest(p) else { return nil }
        if h.part == "monitor.pageDots" {
            // One hit per drawn dot, so its index survives in the rect; the strip past the last dot is bezel.
            guard let i = dot(at: p) else { return Hit(element: id, part: nil, rect: h.rect) }
            let x0 = context.layout.x(CoreLayout.pageDots.x)
            return Hit(element: id, part: h.part, rect: ArtRect(x0 + i * CoreLayout.pageDotPitch - 1, h.rect.y, 4, h.rect.h))
        }
        return Hit(element: id, part: h.part, rect: h.rect)
    }

    /// The page dot under `p` (drawn dots only: one per page in use, at most 8).
    func dot(at p: ArtPoint) -> Int? {
        guard let s = state, context.layout.rect(CoreLayout.pageDots).contains(p) else { return nil }
        let i = (p.x - context.layout.x(CoreLayout.pageDots.x)) / CoreLayout.pageDotPitch
        return i >= 0 && i < min(8, s.pageCount()) ? i : nil
    }

    /// The page a carry hovering at `p` spring-loads: a page dot of a lit desktop, or INPUT (the next HDMI page).
    func springPage(at p: ArtPoint) -> Int? {
        guard let s = state, s.monitor.power == .on, machine?.showsTokens == true || s.monitor.av else { return nil }
        // MARK: harden
        if context.layout.rect(CoreLayout.input).contains(p) { return MonitorMachine.springInputPage(s) }
        guard let i = dot(at: p), i != s.monitor.page || s.monitor.av else { return nil }
        return i
    }

    /// Pages whose dot is blinking now.
    var blinkingPages: Set<Int> { dotBlink?.pages ?? [] }

    /// Blinks the dots of `pages` (new files landed there) three times.
    func blinkDots(_ pages: Set<Int>) {
        guard !pages.isEmpty, state?.monitor.power == .on else { return }
        dotBlink = (pages.union(dotBlink?.pages ?? []), 0)
        refresh()
    }

    /// INPUT does nothing while the display is off, so it does not light up either.
    private var inputLive: Bool { state?.monitor.power == .on }

    public func hover(_ hit: Hit?) -> Bool {
        if hit?.part == "monitor.screen", machine?.overlay == .av {
            followReduceMotion()  // MARK: harden
            let wasMoving = machine?.logo.isMoving ?? false
            machine?.wakeLogo()
            return !wasMoving && (machine?.logo.isMoving ?? false)
        }
        return false
    }

    public func hoverStyle(_ hit: Hit) -> HoverStyle {
        if hit.part == "monitor.input", !inputLive { return .none }
        return hit.part == "monitor.screen" || hit.part == nil ? .none : .standard
    }

    public func tooltip(_ hit: Hit) -> TooltipSpec? {
        guard let s = state, let m = machine else { return nil }
        let title: String?
        var detail: String?
        switch hit.part {
        case "monitor.power":
            title = s.access == .notConnected && s.monitor.power == .on ? "Connect Desktop"
                : (s.monitor.power == .on ? "Turn Display Off" : "Turn Display On")
            if let badge = m.badge { detail = "\(badge.dropFirst()) new while off" }
        case "monitor.input":
            guard inputLive else { return nil }
            title = "Input"
            detail = MonitorMachine.osdText(s)
        case "monitor.pageDots":
            title = "HDMI \(dotIndex(at: hit) + 1)"
        default:
            title = nil
        }
        return title.map { TooltipSpec(title: $0, detail: detail, anchor: hit.rect) }
    }

    // MARK: Gestures

    public func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard let s = state else { return .pass }
        switch gesture {
        case .press:
            let pressable = hit.part == "monitor.power" || (hit.part == "monitor.input" && inputLive)
                || hit.part.map { cardButtons[$0] != nil } == true
            setPressed(pressable ? hit.part : nil)
            return hit.part == "monitor.screen" ? .pass : .handled
        case .cancelPress:
            setPressed(nil)
            return .handled
        case let .click(_, mods, _):
            setPressed(nil)
            switch hit.part {
            case "monitor.power":
                context.dispatch(MonitorMachine.powerAction(s))
            case "monitor.input":
                if s.monitor.power == .on { context.dispatch(.cycleInput) }
            case "monitor.pageDots":
                if s.monitor.power == .on, dotIndex(at: hit) < s.pageCount() { context.dispatch(.setPage(dotIndex(at: hit))) }
            case "card.show":
                context.dispatch(.requestConnect)
            case "card.keepHidden":
                context.dispatch(.power(false))
            case "card.openSettings":
                context.dispatch(.requestPrivacySettings)
            case "card.chooseFolder":
                context.dispatch(.requestChooseFolder)
            case "monitor.screen":
                if mods.isEmpty { context.selection.clear() }
                screen.refreshIfSelectionChanged()
            default:
                return .pass
            }
            return .handled
        case let .dragBegan(from, at, mods):
            setPressed(nil)
            guard hit.part == "monitor.screen", screen.showsTokens else { return .pass }
            let marquee = screen.beginMarquee(from: from, mods: mods)
            marquee.moved(to: at, mods: mods)
            return .drag(marquee)
        case let .scroll(_, delta, _):
            return scrollPages(delta, s)
        }
    }

    /// Two-finger scroll over the screen pages (content moving left shows the next page).
    private func scrollPages(_ delta: SIMD2<Float>, _ s: DeskState) -> GestureResponse {
        guard s.monitor.power == .on, !s.monitor.av else { return .pass }
        scrollIdle = 0
        guard !scrollLocked else { return .handled }
        scrollAccum += delta
        let d = abs(scrollAccum.x) >= abs(scrollAccum.y) ? scrollAccum.x : scrollAccum.y
        if abs(d) >= Self.pageScroll {
            let page = s.monitor.page + (d < 0 ? 1 : -1)
            if page >= 0, page < s.pageCount() { context.dispatch(.setPage(page)) }
            scrollAccum = .zero
            scrollLocked = true
        }
        return .handled
    }

    private func dotIndex(at hit: Hit) -> Int {
        max(0, (hit.rect.x + 1 - context.layout.x(CoreLayout.pageDots.x)) / CoreLayout.pageDotPitch)
    }

    private func setPressed(_ part: String?) {
        guard part != pressedPart else { return }
        pressedPart = part
        let layout = context.layout
        var z = context.placementZ("monitor.pageDots") + 0.6
        switch part {
        case "monitor.power":
            pressedNode.texture = TextureFactory.texture(MonitorArt.powerButton(pressed: true).image)
            context.space.place(pressedNode, at: layout.rect(CoreLayout.power))
        case "monitor.input":
            pressedNode.texture = TextureFactory.texture(MonitorArt.inputButton(pressed: true).image)
            context.space.place(pressedNode, at: layout.rect(CoreLayout.input))
        case let name? where cardButtons[name] != nil && context.font != nil && Self.buttonTitles[name] != nil:
            let image = ScreenCard.button(Self.buttonTitles[name]!, primary: ScreenCard.primaryButtons.contains(name),
                                          pressed: true, font: context.font!)
            pressedNode.texture = TextureFactory.texture(image)
            context.space.place(pressedNode, at: ArtRect(origin: cardButtons[name]!.origin, size: image.size))
            z = context.placementZ("monitor.screen") + 0.35
        default:
            pressedNode.isHidden = true
            return
        }
        pressedNode.zPosition = z
        pressedNode.isHidden = false
    }

    public func menu(_ hit: Hit) -> MenuSpec? {
        state.map(MenuSpec.monitor)
    }

    public func accessibilityItems() -> [AXItem] {
        guard let s = state else { return [] }
        let layout = context.layout
        var items = [
            AXItem(id: "monitor.power", label: s.monitor.power == .on ? "Turn Display Off" : "Turn Display On",
                   role: .button, frame: layout.rect(CoreLayout.powerHit)),
            AXItem(id: "monitor.input", label: "Input: \(MonitorMachine.osdText(s))", role: .button,
                   frame: layout.rect(CoreLayout.input)),
        ]
        for (name, r) in cardButtons.sorted(by: { $0.key < $1.key }) {
            items.append(AXItem(id: name, label: Self.buttonTitles[name] ?? name, role: .button, frame: r))
        }
        return items
    }

    static let buttonTitles = [
        "card.show": "Show", "card.keepHidden": "Keep Hidden", "card.openSettings": "Open Settings",
        "card.chooseFolder": "Choose Folder…",
    ]

    // MARK: Frames

    public var needsFrames: Bool {
        (machine?.needsFrames ?? false) || scrollAccum != .zero || scrollLocked || dotBlink != nil || fade != nil
    }

    // MARK: harden
    /// With Reduce Motion the AV logo holds still where it is (no bounce, no sparkle); without, it bounces when woken.
    private func followReduceMotion() {
        if machine?.logoStill != context.reduceMotion { machine?.holdLogoStill(context.reduceMotion) }
    }

    /// While the AV logo is all the monitor animates: the time until its picture next changes (`MonitorMachine`), else
    /// nil.
    var slowFrameInterval: Double? {
        guard scrollAccum == .zero, !scrollLocked, dotBlink == nil, fade == nil else { return nil }
        return machine?.logoFrameInterval()
    }

    public func step(_ dt: Double) {
        followReduceMotion()  // MARK: harden: Reduce Motion turned on while the logo bounces stops it where it is.
        if scrollAccum != .zero || scrollLocked {
            scrollIdle += dt
            if scrollIdle > 0.25 {
                scrollAccum = .zero
                scrollLocked = false
            }
        }
        if let b = dotBlink {
            dotBlink = b.t + dt >= Self.dotBlinkDuration ? nil : (b.pages, b.t + dt)
            if machine?.needsFrames != true { refresh() }
        }
        if let f = fade {
            let t = f.t + dt
            fade = t + 1e-9 >= Double(f.frames.count) * MonitorMachine.crtFrameTime ? nil : (f.frames, t)
            if machine?.needsFrames != true { refresh() }
        }
        guard machine?.needsFrames == true else { return }
        machine?.step(dt)
        refresh()
    }

    public func settle() {
        machine?.settle()
        fade = nil
        scrollAccum = .zero
        scrollLocked = false
        dotBlink = nil
        refresh()
    }
}
