/// A desk-mat command from its context menu or the status item (DESIGN §2.2 E9 context menu, §4.9 Smooth Desk Mat).
/// The scene's mat plays it on the cloth and commits the pose once the cloth settles (`matSettled`): layout only,
/// and not journaled (moving the mat changes no token's place).
public enum MatCommand: Sendable, Hashable {
    /// Smooth Mat: the face-up corners tugged outward for 20 frames (bumps and folds stay).
    case smooth
    /// Unfold: a folded flap swings back flat.
    case unfold
    /// Turns the mat by this many degrees (the menu's −15° / +15°), as far as it fits the desk.
    case rotate(degrees: Float)
    /// Turns the mat back square to the desk.
    case straighten
    case size(MatSize)
    /// Peek Under: the edge nearest the mat's middle lifts for 1.5 s.
    case peekUnder
    /// Lays a fresh, flat mat at the default place, size and angle, with the keyboard back on it.
    case reset
}

/// The mat's menu sizes (DESIGN §2.2 E9: 96–300 × 48–104, multiples of 6).
public enum MatSize: String, Sendable, CaseIterable {
    case small, medium, large

    /// Rest width and depth in art px; medium is the default mat.
    public var dimensions: SIMD2<Float> {
        switch self {
        case .small: SIMD2(150, 60)
        case .medium: SIMD2(204, 84)
        case .large: SIMD2(270, 102)
        }
    }

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// The size whose dimensions are `size` (within a pixel), if any.
    public static func matching(_ size: SIMD2<Float>) -> MatSize? {
        allCases.first { abs($0.dimensions.x - size.x) < 1 && abs($0.dimensions.y - size.y) < 1 }
    }
}
