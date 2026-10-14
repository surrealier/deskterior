import DeskCore
import DeskPixels
import SpriteKit

extension ToastKey {
    /// The English toast text (the L10n table takes over in M12).
    public var text: String {
        switch self {
        case .containerFull: "That's full."
        case .accessDenied: "No access to the Desktop folder."
        case .notYetAvailable: "Not available yet."
        case .drivesReadOnly: "Use Finder to copy to drives."
        // MARK: files
        case .fileChanged: "It changed on disk. Nothing was done."
        case .fileGone: "That file is gone already."
        case .fileNotPermitted: "macOS did not allow that."
        case .usePutBack: "Use Finder's Put Back."
        case .someNotDone: "Some items stayed where they were."
        case .fileFailed: "That did not work. Nothing changed."
        case .dropHoldsDesk: "That folder holds the desk."
        case .ejectFailed: "The drive could not be ejected."
        case .nameTaken: "Too many items with that name."
        }
    }
}

/// Pixel toasts on the L9 ui layer: one short line on a dark tab that drops in from the top of the visible band
/// over the monitor, holds, and lifts away. A new toast replaces the current one. Bounded (≈2.4 s), emissive.
final class ToastView {
    static let hold = 2.0
    static let slide = 0.2

    let node = SKSpriteNode()
    private(set) var key: ToastKey?
    private var age: Double = 0
    private var image: PixelBuffer?
    private var restingRect: ArtRect?
    /// Canvas rect while shown.
    private(set) var rect: ArtRect?

    init(z: CGFloat) {
        node.zPosition = z
        node.isHidden = true
    }

    var needsFrames: Bool { key != nil }

    func show(_ key: ToastKey, font: PixelFont?, layout: SceneLayout, space: ArtSpace) {
        guard let font else { return }
        let text = PixelText.shadowed(key.text, .neutral9, shadow: .neutral0, font: font)
        let w = text.width + 10, h = text.height + 6
        var c = PixelCanvas(width: w, height: h + 1)
        c.roundedRectFill(ArtRect(0, 1, w, h), radius: 2, .neutral0)
        c.roundedRectFill(ArtRect(0, 0, w, h), radius: 2, .walnut4)
        c.roundedRectFill(ArtRect(1, 1, w - 2, h - 2), radius: 1, .neutral1)
        c.blit(text, at: ArtPoint(5, 3))
        image = c.buffer
        self.key = key
        age = 0
        // On the wall just above the monitor (over its top edge when the wall is short).
        let monitor = layout.rect(CoreLayout.monitorBody)
        restingRect = ArtRect(monitor.midX - c.width / 2, max(layout.visible.minY + 3, monitor.minY - c.height - 3), c.width, c.height)
        node.texture = TextureFactory.texture(c.buffer)
        place(space)
    }

    func hide() {
        key = nil
        node.isHidden = true
        rect = nil
    }

    func step(_ dt: Double, space: ArtSpace) {
        guard key != nil else { return }
        age += dt
        if age >= Self.hold + 2 * Self.slide { hide() } else { place(space) }
    }

    private func place(_ space: ArtSpace) {
        guard let r = restingRect else { return }
        let inT = min(1, age / Self.slide), outT = max(0, (age - Self.hold - Self.slide) / Self.slide)
        let lift = Int(((1 - inT) + outT) * Double(r.h + 4))
        let shown = r.offsetBy(0, -lift)
        space.place(node, at: shown)
        node.isHidden = false
        rect = shown
    }
}
