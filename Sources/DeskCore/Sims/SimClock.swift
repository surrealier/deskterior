/// The step the sims take: the frame loop's fixed 1/60 s, never longer than `maxStep`; nil for a step that is not
/// finite and positive (DESIGN §4.6: a hiccup must never blow a sim up).
enum SimClock {
    static let maxStep: Float = 1.0 / 30

    static func step(_ dt: Float) -> Float? {
        dt.isFinite && dt > 0 ? min(dt, maxStep) : nil
    }
}
