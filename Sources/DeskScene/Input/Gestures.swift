import DeskCore

/// What the `InputRouter` hands an element (DESIGN §2.1). Points are canvas art px (continuous, y-down).
public nonisolated enum Gesture: Sendable, Equatable {
    /// The button went down on the element (buttons show pressed; tokens select, Finder-style).
    case press(SIMD2<Float>, InputEvent.Modifiers)
    /// Released without dragging; `count` 2 is a double-click.
    case click(SIMD2<Float>, InputEvent.Modifiers, count: Int)
    /// The pointer moved past `InputRouter.dragThreshold` from `from` with the button down.
    case dragBegan(from: SIMD2<Float>, at: SIMD2<Float>, InputEvent.Modifiers)
    /// A press that will not become a click (it turned into a drag nobody took, or was cancelled).
    case cancelPress
    /// Two-finger scroll over the element: art px, y-down.
    case scroll(SIMD2<Float>, delta: SIMD2<Float>, InputEvent.Modifiers)

    /// Where the gesture happened (`cancelPress` has no point).
    public var point: SIMD2<Float>? {
        switch self {
        case let .press(p, _), let .click(p, _, _), let .dragBegan(_, p, _), let .scroll(p, _, _): p
        case .cancelPress: nil
        }
    }
}

/// An element's answer to a gesture.
public enum GestureResponse {
    case handled
    /// The element takes the drag; the router feeds the controller until release or Esc.
    case drag(any DragController)
    /// Not for this element: the router falls back (bare-desk behaviour).
    case pass
}

/// Follows one drag (a token carry, a marquee, later a drawer pull or a mat grab). After `ended` or
/// `cancelled` it may keep animating (a spring-back) until `isFinished`; the scene keeps stepping it.
@MainActor
public protocol DragController: AnyObject {
    func moved(to p: SIMD2<Float>, mods: InputEvent.Modifiers)
    /// Released at `p`; `velocity` in art px/s (EMA over the last 50 ms, × 0.8, clamped; fling input).
    func ended(at p: SIMD2<Float>, velocity: SIMD2<Float>, mods: InputEvent.Modifiers)
    /// Esc, a right-click or the window going away: undo the drag's visible effect.
    func cancelled()
    func step(_ dt: Double)
    var needsFrames: Bool { get }
    var isFinished: Bool { get }
}

/// Where dropped tokens go (DESIGN §2.1 DropResolver).
public nonisolated enum DropVerdict: Sendable, Equatable {
    /// Move the tokens here (the reducer applies swap and pour rules).
    case accept(Location)
    /// Refused: "BONK", a 1-px shake, and the tokens spring back. The toast says why, when there is one.
    case bonk(ToastKey?)
}

/// How the hover ring of a hit is drawn.
public nonisolated enum HoverStyle: Sendable {
    /// The room's default: a ring round the part's rect, or the element's silhouette outlined.
    case standard
    /// No ring (surfaces such as the screen's empty area).
    case none
    /// A ready-made ring image at a canvas position.
    case image(PixelBuffer, at: ArtPoint)
}

/// A hover tooltip (DESIGN §2.1): a Galmuri9 title line and an optional detail line.
public nonisolated struct TooltipSpec: Sendable, Equatable {
    public var title: String
    public var detail: String?
    /// The canvas rect the tooltip points at (it sits below it, or above near the bottom edge).
    public var anchor: ArtRect

    public init(title: String, detail: String? = nil, anchor: ArtRect) {
        self.title = title
        self.detail = detail
        self.anchor = anchor
    }
}

/// One accessible thing in the scene (DESIGN §4.5): `DeskView` turns these into `NSAccessibilityElement`s.
public nonisolated struct AXItem: Sendable, Equatable {
    public enum Role: Sendable, Equatable { case button, token, container, group }

    public var id: String
    public var label: String
    public var role: Role
    /// Canvas art px.
    public var frame: ArtRect
    public var token: TokenKey?

    public init(id: String, label: String, role: Role, frame: ArtRect, token: TokenKey? = nil) {
        self.id = id
        self.label = label
        self.role = role
        self.frame = frame
        self.token = token
    }
}

/// What the scene asks of the app besides model actions.
public nonisolated enum SceneRequest: Sendable, Equatable {
    /// Find Item… / Inventory (⌘F).
    case inventory
    /// Show a context menu at a canvas point.
    case menu(MenuSpec, at: SIMD2<Float>)
    /// An app command picked from a scene menu or card (Pause Desk, Settings…).
    case command(MenuCommand)
}

/// Keyboard commands on the desk (DESIGN §2.1 and Errata 1). There are no destructive key equivalents: no ⌘⌫.
public nonisolated enum KeyCommand: Sendable, Equatable {
    case quickLook
    case open
    case copy
    case selectAll
    case find
    case undo
    case redo
    case escape
    /// Arrow keys move the selection on the screen grid.
    case move(dx: Int, dy: Int)

    /// The command for a key event: `characters` is `charactersIgnoringModifiers` (layout-aware) and wins over
    /// the US-layout `keyCode` fallback.
    public static func from(keyCode: UInt16, characters: String? = nil, mods: InputEvent.Modifiers) -> KeyCommand? {
        let command = mods.contains(.command)
        switch keyCode {
        case 49 where !command: return .quickLook          // Space
        case 53: return .escape                              // Esc
        case 123: return .move(dx: -1, dy: 0)
        case 124: return .move(dx: 1, dy: 0)
        case 125: return command ? .open : .move(dx: 0, dy: 1)
        case 126: return .move(dx: 0, dy: -1)
        default: break
        }
        guard command else { return nil }
        let char = characters?.lowercased().first ?? usLayout[keyCode]
        switch char {
        case "o": return .open
        case "c": return .copy
        case "a": return .selectAll
        case "f": return .find
        case "z": return mods.contains(.shift) ? .redo : .undo
        default: return nil
        }
    }

    /// Parses a demo-script key name: `space`, `esc`, `left`/`right`/`up`/`down`, `cmd+o`, `cmd+down`, `cmd+c`,
    /// `cmd+a`, `cmd+f`, `cmd+z`, `shift+cmd+z`.
    public init?(name: String) {
        let parts = name.lowercased().split(separator: "+").map(String.init)
        var mods: InputEvent.Modifiers = []
        for p in parts.dropLast() {
            switch p {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: return nil
            }
        }
        let keys: [String: UInt16] = [
            "space": 49, "esc": 53, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
            "o": 31, "c": 8, "a": 0, "f": 3, "z": 6,
        ]
        guard let key = parts.last, let code = keys[key], let cmd = KeyCommand.from(keyCode: code, characters: key.count == 1 ? key : nil, mods: mods)
        else { return nil }
        self = cmd
    }

    /// US-layout key codes of the letters we use.
    private static let usLayout: [UInt16: Character] = [31: "o", 8: "c", 0: "a", 3: "f", 6: "z"]
}
