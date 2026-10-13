/// The phone on its stand (DESIGN §2.2 E4): `faceUp ↔ flipping ↔ faceDown`.
///
/// A click flips it through the three edge frames (`PropArt.PhoneFace.flip1…flip3`), one every `frameDuration`.
/// The model commits at the start of a flip (`committed`: dispatch `action(committing:model:)`), so face-down hides
/// at once; a click mid-flip turns it back from the frame it is on. Drops are accepted only face-up with room
/// ("bloop"); otherwise they bonk. Face-up it glows. Pure; time comes in through `step(_:)`.
public struct PhoneMachine: Sendable, Equatable {
    public struct Params: Hashable, Sendable {
        /// Seconds per flip frame (three frames per flip).
        public var frameDuration: Float = 1.0 / 12

        public init() {}

        public static let standard = Params()
    }

    public enum Phase: Hashable, Sendable {
        case faceUp
        /// Turning toward face-down (`toFaceDown`) or face-up; `elapsed` seconds into the three frames.
        case flipping(toFaceDown: Bool, elapsed: Float)
        case faceDown
    }

    public enum Event: Hashable, Sendable {
        /// The flip started: the model's `faceDown` becomes this (dispatch `.phoneFlip`).
        case committed(faceDown: Bool)
        /// The flip finished.
        case landed(faceDown: Bool)
    }

    public var params: Params
    public private(set) var phase: Phase

    public init(_ state: PhoneState = PhoneState(), params: Params = .standard) {
        self.params = params
        self.phase = state.faceDown ? .faceDown : .faceUp
    }

    /// The committed state (a flip's destination while flipping).
    public var state: PhoneState {
        switch phase {
        case .faceUp: PhoneState(faceDown: false)
        case .faceDown: PhoneState(faceDown: true)
        case let .flipping(toFaceDown, _): PhoneState(faceDown: toFaceDown)
        }
    }

    var flipDuration: Float { 3 * params.frameDuration }

    /// The sprite face for this moment.
    public var face: PropArt.PhoneFace {
        switch phase {
        case .faceUp: return .up
        case .faceDown: return .down
        case let .flipping(toFaceDown, elapsed):
            let i = min(2, max(0, Int(elapsed / params.frameDuration)))
            let frames: [PropArt.PhoneFace] = toFaceDown ? [.flip1, .flip2, .flip3] : [.flip3, .flip2, .flip1]
            return frames[i]
        }
    }

    /// The minis show (and can be dragged out) only face-up at rest.
    public var showsContents: Bool { phase == .faceUp }
    /// The lit screen faces the room (light mask: phone glow).
    public var isEmissive: Bool { face == .up || face == .flip1 }
    public var needsFrames: Bool { if case .flipping = phase { true } else { false } }

    /// A token dropped on the phone: accepted face-up with room for one more, else it bonks.
    public func canAccept(count: Int) -> Bool {
        phase == .faceUp && count < ContainerSpec.phone.hardCap
    }

    /// Click: starts a flip, or turns a flip in progress back.
    public mutating func flip() -> [Event] {
        switch phase {
        case .faceUp:
            phase = .flipping(toFaceDown: true, elapsed: 0)
            return [.committed(faceDown: true)]
        case .faceDown:
            phase = .flipping(toFaceDown: false, elapsed: 0)
            return [.committed(faceDown: false)]
        case let .flipping(toFaceDown, elapsed):
            phase = .flipping(toFaceDown: !toFaceDown, elapsed: max(0, flipDuration - elapsed))
            return [.committed(faceDown: !toFaceDown)]
        }
    }

    /// The model action for a `committed(faceDown:)` event. `.phoneFlip` toggles, so it is dispatched only when the
    /// model differs: a repeated or late commit never flips the model the wrong way.
    public static func action(committing faceDown: Bool, model: PhoneState) -> DeskAction? {
        model.faceDown == faceDown ? nil : .phoneFlip
    }

    /// The model changed under the machine (undo, Clear the Desk, Show on Desk): jump to it without animating.
    public mutating func sync(_ state: PhoneState) {
        if self.state != state { phase = state.faceDown ? .faceDown : .faceUp }
    }

    public mutating func step(_ dt: Float) -> [Event] {
        guard case let .flipping(toFaceDown, elapsed) = phase, let dt = SimClock.step(dt) else { return [] }
        let t = elapsed + dt
        if t >= flipDuration {
            phase = toFaceDown ? .faceDown : .faceUp
            return [.landed(faceDown: toFaceDown)]
        }
        phase = .flipping(toFaceDown: toFaceDown, elapsed: t)
        return []
    }
}
