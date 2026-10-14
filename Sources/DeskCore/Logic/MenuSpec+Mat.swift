/// The desk mat's context menu (DESIGN §2.2 E9): Smooth Mat, Unfold, Rotate −15° / +15° / Straighten, Size S/M/L,
/// Peek Under, List Items Under Mat and Reset Mat. What can be done depends on the live cloth, which the scene reads
/// into a `MatInfo` (`ClothSim.canTransform` disables a turn or a size that would not change anything).
extension MenuSpec {
    /// What the mat's menu needs from the scene's cloth.
    public struct MatInfo: Sendable, Equatable {
        /// A flap lies folded over (Unfold).
        public var folded = false
        /// Rotate −15° turns clockwise on screen, +15° counter-clockwise (the cloth's angle is counter-clockwise in the
        /// x/d plane, and d runs up the screen).
        public var canRotateCW = true
        public var canRotateCCW = true
        public var canStraighten = false
        /// Sizes the mat can change to (fitted to the desk), and the menu size it has now, if any.
        public var sizes: Set<MatSize> = Set(MatSize.allCases)
        public var size: MatSize? = .medium
        /// `matMode=flat`: no peeking and no folds.
        public var flat = false
        /// Tokens the mat covers.
        public var under: [TokenKey] = []

        public init() {}
    }

    /// Right-click on the mat. Listing what lies under it is an explicit menu action, so it may name what the mat
    /// hides (§2.1 non-destructive un-hiding); picking a name flies that token to the monitor, as List Contents does.
    public static func mat(_ s: DeskState, _ info: MatInfo) -> MenuSpec {
        let monitor = firstFreeCell(s)
        let named = Placement.byName(info.under.filter(s.tokens.contains), in: s.tokens)
        var list = named.prefix(listLimit).enumerated().map { i, key in
            MenuItem("under.\(i)", s.tokens.meta(of: key)?.displayName ?? "?", .moveTo([key], monitor))
        }
        if named.count > listLimit {
            list.append(.separator)
            list.append(MenuItem("under.more", "\(named.count - listLimit) More…", .inventory))
        }
        let sizes = MatSize.allCases.map { size in
            MenuItem("size.\(size.rawValue)", size.title, .mat(.size(size)),
                     enabled: info.size != size && info.sizes.contains(size), checked: info.size == size)
        }
        return MenuSpec([
            MenuItem("smoothMat", "Smooth Mat", .mat(.smooth)),
            MenuItem("unfoldMat", "Unfold", .mat(.unfold), enabled: info.folded),
            .separator,
            MenuItem("rotate", "Rotate", submenu: [
                MenuItem("rotate.cw", "Rotate −15°", .mat(.rotate(degrees: -15)), enabled: info.canRotateCW),
                MenuItem("rotate.ccw", "Rotate +15°", .mat(.rotate(degrees: 15)), enabled: info.canRotateCCW),
                MenuItem("rotate.straighten", "Straighten", .mat(.straighten), enabled: info.canStraighten),
            ]),
            MenuItem("size", "Size", submenu: sizes),
            .separator,
            MenuItem("peekUnder", "Peek Under", .mat(.peekUnder), enabled: !info.flat),
            MenuItem("listUnder", "List Items Under Mat", submenu: list, enabled: !list.isEmpty),
            .separator,
            MenuItem("resetMat", "Reset Mat", .mat(.reset)),
        ])
    }
}
