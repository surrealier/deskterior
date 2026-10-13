/// Lamp-only darkness (DESIGN §2.1 visibility matrix, §2.2 E12): a token drawn where the light has fallen below
/// level 3 is a silhouette. Hovering it shows only a faint outline (no name, no tooltip) and clicks, drags and
/// menus on it do nothing, so the lamp, the monitor's glow and a face-up phone work as flashlights for searching.
/// The rule is about where a token is drawn, not where it lives: any element that reports token hits through
/// `Hit.token` gets it from the room's hit test.
public enum DarkHit {
    /// The light level a token needs to be made out.
    public static let minimumLevel = 3
    /// The share of a token's drawn rect that must be lit to at least `minimumLevel`.
    public static let minimumLitShare = 1.0 / 3

    /// Whether a token drawn in `rect` can be seen (and so hovered and picked) under `mask` and `ambient`.
    public static func isLit(_ rect: ArtRect, mask: LightMask, ambient: Int) -> Bool {
        mask.litFraction(rect, atLeast: minimumLevel, ambient: ambient) >= minimumLitShare
    }
}
