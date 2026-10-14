/// The keyboard's turn on the desk (Errata 26): it rides the particles it weighs down, so it turns with them.
extension ClothSim {
    /// The angle (radians) of the frame the keyboard's weighed particles fit now, nil without a keyboard: 0 on a
    /// square mat, the mat's own turn on a turned one, and whatever a carry or a turn swings it to in between. A
    /// restored mat gives the angle it was saved with (the particles are the pose).
    public var keyboardAngle: Float? {
        guard keyboardOffset != nil else { return nil }
        let weighed = parts.indices.filter { parts[$0].weighted }
        guard weighed.count >= 3 else { return nil }
        let a = fitFrame(weighed).angle
        return a.isFinite ? a : nil
    }
}
