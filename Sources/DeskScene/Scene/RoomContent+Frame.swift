import DeskCore

/// The picture frame in the room (Erratum 33): its element, and the scene's answers for the app (Finder drops onto the
/// frame, demo targets, VoiceOver).
extension RoomContent {
    /// The installed picture frame element (dormant while the frame is not in the room).
    var frameElement: FrameElement? { extras.lazy.compactMap { $0 as? FrameElement }.first }
}

extension DeskScene {
    /// The picture frame's canvas rect while it is in the room and routed (nil: put away with the wall shelf, or a
    /// desktop widget took its place).
    public var pictureFrameRect: ArtRect? {
        guard let room, let frame = room.frameElement, room.routing.contains(where: { $0 === frame }) else { return nil }
        return frame.rect
    }

    /// Whether canvas point `p` is over the picture frame, front to back as a click would find it: a Finder drop there
    /// only reads one photo and never imports (`DropInController`).
    public func isOverPictureFrame(_ p: SIMD2<Float>) -> Bool {
        guard let room else { return false }
        return room.target(at: ArtPoint(Int(p.x.rounded(.down)), Int(p.y.rounded(.down))))?.element is FrameElement
    }
}
