/// The pointer drawn into recorded demo frames (`--demo-record`, the README's hero GIF; `docs/DEMOS.md`). The scene
/// draws no cursor (DESIGN §2.1), so without it a recording shows things moving by themselves. Snapshots and the app
/// never draw it. An arrow with its hot spot at the tip, filled grey while the button is held, and a ring that
/// spreads from the tip for a few frames after each press.
public enum DemoCursorArt {
    /// The arrow, its tip (the hot spot) at the top-left pixel.
    public static let arrow = IndexedSprite("""
        k.........
        kk........
        k9k.......
        k99k......
        k999k.....
        k9999k....
        k99999k...
        k999999k..
        k9999999k.
        k99999kkkk
        k99kk99k..
        k9k.k99k..
        kk...k99k.
        .....k99k.
        ......kk..
        """)

    /// The arrow while a button is held.
    public static let pressed = arrow.remapped([.neutral9: .neutral7])

    /// The click ring, small then large, centred on the hot spot.
    public static let ripples = [
        IndexedSprite("""
            ..kkk..
            .k999k.
            k9...9k
            k9...9k
            k9...9k
            .k999k.
            ..kkk..
            """),
        IndexedSprite("""
            ...kkkkk...
            ..k99999k..
            .k9.....9k.
            k9.......9k
            k9.......9k
            k9.......9k
            k9.......9k
            k9.......9k
            .k9.....9k.
            ..k99999k..
            ...kkkkk...
            """),
    ]

    /// Scene frames (1/60 s) each ripple shows after a press.
    public static let rippleFrames = 6

    /// Draws the pointer into `frame` with its hot spot at `tip` (clipped at the edges). `sincePress` is the number
    /// of scene frames since the last press, or nil when none is recent; the ring shows while it is under
    /// `ripples.count × rippleFrames`.
    public static func stamp(into frame: inout PixelBuffer, tip: ArtPoint, pressed isPressed: Bool, sincePress: Int?) {
        if let n = sincePress, n >= 0, n / rippleFrames < ripples.count {
            let ring = ripples[n / rippleFrames]
            frame.blit(ring.render(), at: ArtPoint(tip.x - ring.w / 2, tip.y - ring.h / 2))
        }
        frame.blit((isPressed ? pressed : arrow).render(), at: tip)
    }
}
