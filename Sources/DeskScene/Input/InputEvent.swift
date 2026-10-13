import DeskCore

/// One pointer or key event, already converted to canvas art coordinates (DESIGN §4.2). Produced by the app's
/// `DeskView` (and later by demo scripts), consumed by `SceneHost`.
public nonisolated struct InputEvent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case down, up, drag, move, scroll, rightDown, key
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var kind: Kind
    /// Canvas art position (y-down, continuous): pixel `(x, y)` covers `[x, x+1) × [y, y+1)`.
    public var art: SIMD2<Float>
    public var mods: Modifiers
    public var clickCount: Int
    /// Scroll delta in art px, y-down (the direction the content moves).
    public var scroll: SIMD2<Float>
    /// Event time in seconds (`NSEvent.timestamp` for real input).
    public var t: Double
    /// Virtual key code for `.key` events.
    public var keyCode: UInt16

    public init(
        _ kind: Kind, art: SIMD2<Float>, mods: Modifiers = [], clickCount: Int = 0,
        scroll: SIMD2<Float> = .zero, t: Double = 0, keyCode: UInt16 = 0
    ) {
        self.kind = kind
        self.art = art
        self.mods = mods
        self.clickCount = clickCount
        self.scroll = scroll
        self.t = t
        self.keyCode = keyCode
    }

    /// The canvas art pixel under the event.
    public var artPixel: ArtPoint {
        ArtPoint(Int(art.x.rounded(.down)), Int(art.y.rounded(.down)))
    }
}
