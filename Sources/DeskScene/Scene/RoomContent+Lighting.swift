import DeskCore
import SpriteKit

/// What the room shows ahead of the model and the clock (DESIGN §2.2 E12–E13, M10): the lamp mid-flicker and the
/// time the clock's minute hand is dragged to. `DeskScene.refreshState` folds these into the `RoomState`
/// (`RoomContent.adjustLighting`), so the lamp, window, sky, clock face and light mask follow them live; every
/// change asks the scene to refresh.
public final class SceneLightOverrides {
    /// The time the clock previews (nil: the real time).
    public internal(set) var previewTime: WallTime? {
        didSet { if previewTime != oldValue { onChange?() } }
    }
    /// The lamp as a flicker frame shows it (nil: as the model has it).
    public internal(set) var lampLit: Bool? {
        didSet { if lampLit != oldValue { onChange?() } }
    }
    /// The time the room shows without a preview (the scene's clock at the last refresh).
    public internal(set) var clockTime = WallTime(hour: 0, minute: 0)
    var onChange: (() -> Void)?
}

/// A token the light does not reach (`DarkHit`): the room's hit test answers with this instead of the token's own
/// element, so hovering it shows a faint outline and nothing else, and clicks, drags, scrolls and menus on it do
/// nothing.
final class DarkTokenElement: DeskElement {
    let id = "dark"
    let root = SKNode()

    func layout(_ layout: SceneLayout) {}
    /// Never in the routing order: `RoomContent.darkFiltered` hands it out.
    func hitTest(_ p: ArtPoint) -> Hit? { nil }

    /// A 1-px outline round the token in label white, lit only to `ringLevel` (`HoverRingLight`), so it shows
    /// faintly in the dark (no name, no tooltip).
    func hoverStyle(_ hit: Hit) -> HoverStyle {
        let r = hit.rect.insetBy(-1, -1)
        var c = PixelCanvas(width: r.w, height: r.h)
        c.roundedRectStroke(c.bounds, radius: 2, Self.ink)
        return .image(c.buffer, at: r.origin)
    }

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse { .handled }

    static let ink = Ink.neutral9
    /// The light the outline gets: faint (`577277` at ambient 1), not the full white of a lit ring.
    static let ringLevel = DarkHit.minimumLevel
}

/// The hover ring's own pixels, which the lit pass lights so whatever the pointer finds shows in the dark (the
/// lamp, the wall switch, the clock): at full light, or `DarkTokenElement.ringLevel` for a dark token's outline.
struct HoverRingLight: Equatable {
    let image: PixelBuffer
    let origin: ArtPoint
    let level: Int

    init(element: any DeskElement, image: PixelBuffer, origin: ArtPoint) {
        self.image = image
        self.origin = origin
        level = element is DarkTokenElement ? DarkTokenElement.ringLevel : LightRamp.maxLevel
    }
}

/// What the lit pass lights over the room's mask: the tooltip and toast rects at full light, and the hover ring.
struct LitOverlay: Equatable {
    var rects: [ArtRect] = []
    var ring: HoverRingLight?

    var isEmpty: Bool { rects.isEmpty && ring == nil }

    func apply(to mask: inout LightMask) {
        for r in rects { mask.addRect(r, level: LightRamp.maxLevel, tint: .cool) }
        if let ring { mask.addSprite(ring.image, at: ring.origin, level: ring.level, tint: .cool) }
    }
}

extension RoomContent {
    /// The room's lamp, wall switch, clock, keyboard and plant, each in its placed object's hit-test slot.
    func installRoomControls() {
        func placed(_ id: String) -> () -> PlacedElement? {
            { [unowned self] in elements.first { $0.id == id } }
        }
        install([LampElement(context: context, placed: placed("lamp"))], inSlotOf: "lamp")
        install([RoomSwitchElement(context: context, placed: placed("room.switch"))], inSlotOf: "room.switch")
        install([ClockElement(context: context, placed: placed("clock"))], inSlotOf: "clock")
        install([KeyboardElement(context: context, placed: placed("keyboard"))], inSlotOf: "keyboard")
        install([PlantElement(context: context, placed: placed("plant"))], inSlotOf: "plant")
    }

    /// Dark-token hit filtering (`DarkHit`): a token hit (any element's, through `Hit.token`) where the light has
    /// fallen below level 3 becomes the inert `DarkTokenElement`'s hit over the same rect.
    func darkFiltered(_ hit: Hit, _ element: any DeskElement) -> (hit: Hit, element: any DeskElement) {
        guard hit.token != nil, !isTokenLit(hit.rect) else { return (hit, element) }
        return (Hit(element: Self.darkToken.id, part: "token.dark", rect: hit.rect), Self.darkToken)
    }

    /// After the light changed: re-hover under a resting pointer (a token the light reached or left) and let go of
    /// selected tokens now in the dark.
    func relit() {
        router.refreshHover()
        pruneSelection()
    }

    /// Shown tokens drawn where the light does not reach (`DarkHit`, by their accessibility frames): the selection
    /// lets them go, so keys and menus never act on a token the user cannot see. None while a drag is in hand (a
    /// carry keeps its stack) or while the ambient light alone lets every token be seen.
    func darkTokens() -> Set<TokenKey> {
        guard router.drag == nil, ambient.level < DarkHit.minimumLevel else { return [] }
        var out = Set<TokenKey>()
        for e in extras {
            for item in e.accessibilityItems() {
                if let key = item.token, !isTokenLit(item.frame) { out.insert(key) }
            }
        }
        return out
    }

    /// What the lit pass adds over the light mask: the tooltip and toast, and while the room is dim, the hover ring.
    var litOverlay: LitOverlay {
        LitOverlay(rects: emissiveRects, ring: ambient.level < LightRamp.maxLevel ? hoverRing : nil)
    }

    /// Whether a token drawn in `rect` can be seen under the room's light now.
    func isTokenLit(_ rect: ArtRect) -> Bool {
        DarkHit.isLit(rect, mask: lightMask, ambient: ambient.level)
    }

    /// The level the lit pass gives canvas pixel `p` (mask or ambient).
    func lightLevel(at p: ArtPoint) -> Int {
        lightMask.effectiveLevel(p.x, p.y, ambient: ambient.level)
    }

    /// Folds the clock preview and a lamp flicker into the state the room is about to show; remembers the real
    /// time for the clock.
    func adjustLighting(_ s: inout RoomState) {
        let o = context.lightOverrides
        o.clockTime = s.time
        if let t = o.previewTime { s.time = t }
        if let lit = o.lampLit { s.lights.lampOn = lit }
    }

    private static let darkToken = DarkTokenElement()

    /// The standard ring for a placed object with no named part under the pointer: its silhouette, outlined.
    static func silhouetteRing(_ placed: PlacedElement?) -> HoverStyle {
        guard let placed, !placed.placements.isEmpty else { return .none }
        let b = placed.bounds
        return .image(placed.silhouette().outlined(hoverInk), at: ArtPoint(b.x - 1, b.y - 1))
    }
}

extension DeskScene {
    /// The level the lit pass gives canvas pixel `p` now (0 without a room).
    public func lightLevel(at p: ArtPoint) -> Int {
        room?.lightLevel(at: p) ?? 0
    }

    /// Whether a token drawn in `rect` would be seen (and so hovered and picked) under the room's light now.
    public func isTokenLit(_ rect: ArtRect) -> Bool {
        room?.isTokenLit(rect) ?? true
    }

    /// The clock preview and lamp flicker (nil without a room).
    public var lightOverrides: SceneLightOverrides? { room?.context.lightOverrides }

    /// The element installed for a room object ("lamp", "clock", …), if any.
    public func roomElement(_ id: String) -> (any DeskElement)? {
        room?.extras.first { $0.id == id }
    }

    /// What the pointer rests on: the hit the router hovers (a dark token's is part "token.dark").
    public var hoveredHit: Hit? { room?.router.hovered }
}

/// A short scripted animation for the room's decor (a flicker, a jiggle, a key press): frame `index` of `count`,
/// each `frameTime` long.
struct DecorAnimation: Equatable {
    let count: Int
    let frameTime: Double
    private(set) var elapsed: Double = 0

    init(count: Int, frameTime: Double = DecorAnimation.frameTime) {
        self.count = count
        self.frameTime = frameTime
    }

    /// The juice kit's 12 fps.
    static let frameTime = 1.0 / 12

    /// (A frame's worth of fixed steps sums a hair short of `frameTime`; the slack keeps frames on their step.)
    var index: Int { min(count - 1, Int((elapsed + 1e-9) / frameTime)) }
    var isFinished: Bool { elapsed + 1e-9 >= Double(count) * frameTime }

    mutating func advance(_ dt: Double) { elapsed += dt }
}
