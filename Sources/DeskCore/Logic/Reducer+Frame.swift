/// The picture frame (Erratum 33). Only the pixels are stored: the file was read by the app before the action, so these
/// emit no file effect and no `.persist` (`FrameSaver` follows `state.framePhoto`, as `MemoSaver` follows the memos).
extension Reducer {
    /// `.hangPhoto`, `.removePhoto`.
    static func reduceFrame(_ s: inout DeskState, _ a: DeskAction) -> [Effect] {
        switch a {
        case let .hangPhoto(photo):
            guard s.framePhoto != photo else { return [] }
            s.framePhoto = photo
            return [.wakeLoop]
        case .removePhoto:
            guard s.framePhoto != nil else { return [] }
            s.framePhoto = nil
            return [.wakeLoop]
        default:
            return []
        }
    }
}
