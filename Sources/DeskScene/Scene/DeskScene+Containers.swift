import DeskCore

/// What the containers show, for demo scripts and the app (DESIGN §2.2 E3–E6).
extension DeskScene {
    /// The live rect of an anchor that moves with a container — a drawer's pull and front slide out with it — or
    /// nil for anchors that stay put (use `layout.anchors`).
    public func liveAnchor(_ name: String) -> ArtRect? {
        room?.liveContainerAnchor(name)
    }

    /// Where `key` shows as a mini in an open drawer, the cubby, the face-up phone or the memo clips (canvas px), if
    /// it does.
    public func miniRect(of key: TokenKey) -> ArtRect? {
        room?.containerMiniRect(of: key)
    }

    /// Tokens the containers show as minis now (open drawers, the cubby, the face-up phone, the memo clips).
    public var containerMinis: Set<TokenKey> {
        guard let room else { return [] }
        let elements: [any DeskElement] = [room.riserElement, room.cabinetElement, room.phoneElement,
                                           room.memoClipsElement].compactMap { $0 }
        return elements.reduce(into: Set<TokenKey>()) { $0.formUnion($1.shownTokens) }
    }

    /// The chair's left edge as it rolls now (core px).
    public var chairX: Float? { room?.chairElement?.sim.x }
}
