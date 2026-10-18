import DeskCore

/// The room's side of Put Away (Erratum 30): the dust puff where an object leaves or comes back.
extension RoomContent {
    /// Model animations for putting away and bringing back: a dust puff at the bottom centre of where the object
    /// stands (none for wall decor, none with Reduce Motion). True when it was one of those.
    func playPartition(_ id: AnimationID, _ target: AnimTarget) -> Bool {
        switch (id, target) {
        case let (.putAway, .stowable(object)), let (.bringBack, .stowable(object)):
            if !context.reduceMotion, let name = StowCatalog.spec(object).anchor, let r = layout.anchors[name] {
                context.fx.puff(at: ArtPoint(r.midX, r.maxY))
            }
            return true
        default:
            return false
        }
    }
}
