/// Lights (DESIGN §2.2 E12, §14 M10): the mode, the room light and the desk lamp. Lamp Only is both a menu
/// choice and an emergent state, so `.lights` actions settle into one canonical form before they are stored.
extension LightsState {
    /// Lamp Only as the Lights menu sets it: night, the room light off, the lamp on.
    public static let lampOnly = LightsState(mode: .lampOnly, room: false, lamp: true)

    /// Whether the room light is on as the room shows it (Lamp Only keeps it off, whatever an older layout stored).
    public var roomLightOn: Bool { mode == .lampOnly ? false : room }
    /// Whether the desk lamp is on as the room shows it (Lamp Only keeps it on).
    public var lampLit: Bool { mode == .lampOnly ? true : lamp }

    /// The wall switch or Lights ▸ Room Light.
    public func withRoomLight(_ on: Bool) -> LightsState {
        LightsState(mode: mode, room: on, lamp: lampLit)
    }

    /// The lamp's switch or Lights ▸ Desk Lamp.
    public func withLamp(_ on: Bool) -> LightsState {
        LightsState(mode: mode, room: roomLightOn, lamp: on)
    }

    /// The canonical form of this requested state, coming from `old`:
    /// - choosing Lamp Only sets all three at once (night, room light off, lamp on);
    /// - choosing another mode from Lamp Only turns the room light back on (Night would otherwise settle straight
    ///   back into Lamp Only);
    /// - Lamp Only is emergent: Night with the room light off and the lamp on is Lamp Only, and Lamp Only with the
    ///   room light switched on, or the lamp off, is plain Night. Auto stays Auto (the clock may bring the day).
    public func settled(from old: LightsState) -> LightsState {
        if mode == .lampOnly && old.mode != .lampOnly { return .lampOnly }
        var s = self
        if old.mode == .lampOnly, s.mode != .lampOnly, s.room == old.room, s.lamp == old.lamp { s.room = true }
        if s.mode == .lampOnly && (s.room || !s.lamp) { s.mode = .night }
        if s.mode == .night && !s.room && s.lamp { s.mode = .lampOnly }
        return s
    }
}

extension Reducer {
    /// `.lights`: stores the settled form of the request (persisted; the scene relights from the model).
    static func reduceLights(_ s: inout DeskState, _ requested: LightsState) -> [Effect] {
        let lights = requested.settled(from: s.lights)
        guard lights != s.lights else { return [] }
        s.lights = lights
        return [.persist, .wakeLoop]
    }
}
