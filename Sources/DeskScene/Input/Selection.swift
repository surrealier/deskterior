import DeskCore

/// The selected tokens (DESIGN §2.1): click selects, ⌘-click toggles, ⇧-click extends, a marquee adds what it
/// covers. Runtime only, never persisted. `primary` is the token keyboard moves start from and whose label shows.
public final class Selection {
    public private(set) var keys: Set<TokenKey> = []
    public private(set) var primary: TokenKey?
    /// Bumped on every change, so views can tell whether to redraw.
    public private(set) var revision = 0

    public init() {}

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }
    public func contains(_ key: TokenKey) -> Bool { keys.contains(key) }
    /// The selection in key order (deterministic action payloads).
    public var sorted: [TokenKey] { keys.sorted() }

    /// Selects exactly `keys` (primary: `primary`, else the lowest key).
    public func set(_ keys: Set<TokenKey>, primary: TokenKey? = nil) {
        let p = primary.flatMap { keys.contains($0) ? $0 : nil } ?? keys.min()
        guard keys != self.keys || p != self.primary else { return }
        self.keys = keys
        self.primary = p
        revision += 1
    }

    public func select(_ key: TokenKey) { set([key], primary: key) }

    public func clear() { set([]) }

    /// A click on `key` with modifiers: ⌘ toggles it, ⇧ adds it, otherwise it becomes the only selection.
    public func click(_ key: TokenKey, mods: InputEvent.Modifiers) {
        if mods.contains(.command) {
            var k = keys
            if k.contains(key) { k.remove(key) } else { k.insert(key) }
            set(k, primary: k.contains(key) ? key : primary)
        } else if mods.contains(.shift) {
            set(keys.union([key]), primary: key)
        } else {
            select(key)
        }
    }

    /// Keeps only live tokens, following re-keys (a safe-save while selected keeps the selection).
    public func follow(_ state: DeskState) {
        let mapped = Set(keys.map(state.currentKey).filter(state.tokens.contains))
        set(mapped, primary: primary.map(state.currentKey))
    }
}
