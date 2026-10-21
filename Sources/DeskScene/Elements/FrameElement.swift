import DeskCore
import SpriteKit

/// The picture frame (Erratum 33): the framed print over the wall shelf, which takes a photo of the user's own. It draws
/// nothing itself (the room's `decor.frame.*` placement shows the print or the photo from `RoomState.framePhoto`, so the
/// lit pass and the CPU agree) and takes the placed print's hits: the silhouette ring, the tooltip "Picture Frame" (no
/// file name, ever), VoiceOver ("Picture Frame", valued "No photo" / "Your photo"), its menu (Choose Photo…, Remove
/// Photo; the room appends Put Away Wall Shelf), a click on the empty frame (Choose Photo…) and carried tokens: one image
/// token asks the app to hang it (`DropVerdict.hang`), anything else bonks with why. Put away with the wall shelf, or
/// with a widget where it hangs, it is dormant.
final class FrameElement: DeskElement {
    let id = "frame"
    let root = SKNode()
    unowned let context: SceneContext
    /// The room's placed print (its sprite and alpha hit tests).
    let placed: () -> PlacedElement?
    private(set) var state: DeskState?

    init(context: SceneContext, placed: @escaping () -> PlacedElement?) {
        self.context = context
        self.placed = placed
    }

    /// The frame's canvas rect while it is in the room.
    var rect: ArtRect? { placed().flatMap { $0.placements.isEmpty ? nil : $0.bounds } }
    /// Whether a photo hangs in the frame (the model's, Erratum 33).
    var hasPhoto: Bool { state?.framePhoto != nil }

    func layout(_ layout: SceneLayout) {}

    func apply(_ s: DeskState) { state = s }

    /// The placed print's pixels (alpha), answered as the frame's body.
    func hitTest(_ p: ArtPoint) -> Hit? {
        guard placed()?.hitTest(p) != nil, let r = rect else { return nil }
        return Hit(element: id, part: nil, rect: r)
    }

    /// The print's silhouette, outlined.
    func hoverStyle(_ hit: Hit) -> HoverStyle { RoomContent.silhouetteRing(placed()) }

    /// "Picture Frame", with how to hang a photo while the frame is empty; never a file name.
    func tooltip(_ hit: Hit) -> TooltipSpec? {
        TooltipSpec(title: L10n.text(.pictureFrame), detail: hasPhoto ? nil : L10n.text(.pictureFrameHelp), anchor: hit.rect)
    }

    /// A click on the empty frame asks for a photo (Choose Photo…); hung, a click is the bare wall's.
    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        guard state != nil else { return .pass }
        switch gesture {
        case .press, .cancelPress: return .handled
        case let .click(_, mods, count):
            // Hung, a click is the bare wall's (it clears the selection); empty, it asks for a photo.
            guard count == 1, mods.isEmpty, !hasPhoto else { return .pass }
            context.request(.command(.choosePhoto))
            return .handled
        case .dragBegan, .scroll: return .pass
        }
    }

    /// One picture token hangs (`DropVerdict.hang`); several, anything else, an alias, a package or an iCloud
    /// placeholder bonk with why (`FramePhoto.refusal(for:)`).
    func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? {
        guard let s = state, hitTest(p) != nil else { return nil }
        guard tokens.count == 1, let key = tokens.first else { return .bonk(.onePhotoAtATime) }
        // A stand-in (a Finder drop's count, `fileDropVerdict`) is no token: it bonks, so nothing imports here.
        guard let meta = s.tokens.meta(of: key) else { return .bonk(.notAPhoto) }
        if let why = FramePhoto.refusal(for: meta) { return .bonk(why) }
        return .hang(key)
    }

    /// Choose Photo…, and Remove Photo while one hangs (`MenuSpec.frame`).
    func menu(_ hit: Hit) -> MenuSpec? { state.map(MenuSpec.frame) }

    /// "Picture Frame", valued "No photo" or "Your photo", over the frame.
    func accessibilityItems() -> [AXItem] {
        guard state != nil, let r = rect else { return [] }
        return [AXItem(id: id, label: L10n.text(.pictureFrame), role: .button, frame: r,
                       value: L10n.text(hasPhoto ? .axFramePhoto : .axFrameEmpty))]
    }
}
