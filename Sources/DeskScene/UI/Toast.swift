import DeskCore
import DeskPixels
import SpriteKit

extension ToastKey {
    /// The English toast text (shown through `L10n.tr` in the current language).
    public var english: String {
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
        case .dropHoldsDesk: "Can't drop the Desktop or a folder holding it."
        case .ejectFailed: "The drive could not be ejected."
        case .nameTaken: "Too many items with that name."
        case .someChanged: "Some changed on disk, so they stayed."
        case .someGone: "Some were gone already."
        case .someNotPermitted: "macOS kept some items where they were."
        case .dropWholeDrive: "Drag files from the drive, not the drive."
        case .filesUnavailable: "The desk isn't connected to its folder."
        case .nothingToUndo: "Nothing to undo there: those items are gone."
        case .fileBusy: "Still working on that."
        case .stoppingCopy: "Stopping the copy…"
        case .undidTrash: "Put back from the Trash."
        case .undidMoveIn: "Sent back where they came from."
        case .undidCopyIn: "Copies moved to the Trash."
        case .undidDropIn: "Sent back; copies moved to the Trash."
        case .cantMoveBack: "macOS would not let it go back."
        case .widgetsOverlap: "Widgets cover part of the desk."
        // MARK: harden
        case .fileLocked: "It's locked, so it stayed. ⌥ copies it."
        case .copiedInstead: "Copied in; the original stayed put."
        case .leftoverCopies: "An interrupted copy left files. See Settings."
        case .someLocked: "Some were locked, so they stayed."
        case .someCopiedInstead: "Some came in as copies; the rest stayed."
        case .copiedNoUndo: "Copied in, but it can't be undone."
        }
    }

    /// The toast text in the current language.
    public var text: String { L10n.tr(english) }
}

/// Pixel toasts on the L9 ui layer: one short line on a dark tab that drops in from the top of the visible band
/// over the monitor, holds, and lifts away. A new toast replaces the current one. Bounded (≈2.4 s), emissive. A
/// progress line (a long drop-in copy) is a toast without a key, renewed while it lasts.
final class ToastView {
    static let hold = 2.0
    static let slide = 0.2

    let node = SKSpriteNode()
    private(set) var key: ToastKey?
    /// The line shown (a key's text, or a progress line).
    private(set) var text: String?
    private var age: Double = 0
    private var image: PixelBuffer?
    private var restingRect: ArtRect?
    /// Canvas rect while shown.
    private(set) var rect: ArtRect?

    init(z: CGFloat) {
        node.zPosition = z
        node.isHidden = true
    }

    var needsFrames: Bool { text != nil }

    func show(_ key: ToastKey, font: PixelFont?, layout: SceneLayout, space: ArtSpace) {
        render(key.text, font: font, layout: layout, space: space, inPlace: false)
        if text != nil { self.key = key }
    }

    /// Shows a progress `line` (no key). While a progress line is up, a new one replaces it in place and renews
    /// its hold, without sliding in again.
    func show(progress line: String, font: PixelFont?, layout: SceneLayout, space: ArtSpace) {
        let inPlace = key == nil && text != nil && age < Self.hold + Self.slide
        render(line, font: font, layout: layout, space: space, inPlace: inPlace)
    }

    private func render(_ line: String, font: PixelFont?, layout: SceneLayout, space: ArtSpace, inPlace: Bool) {
        guard let font else { return }
        let text = PixelText.shadowed(line, .neutral9, shadow: .neutral0, font: font)
        let w = text.width + 10, h = text.height + 6
        var c = PixelCanvas(width: w, height: h + 1)
        c.roundedRectFill(ArtRect(0, 1, w, h), radius: 2, .neutral0)
        c.roundedRectFill(ArtRect(0, 0, w, h), radius: 2, .walnut4)
        c.roundedRectFill(ArtRect(1, 1, w - 2, h - 2), radius: 1, .neutral1)
        c.blit(text, at: ArtPoint(5, 3))
        image = c.buffer
        key = nil
        self.text = line
        age = inPlace ? min(age, Self.slide) : 0
        // On the wall just above the monitor (over its top edge when the wall is short).
        let monitor = layout.rect(CoreLayout.monitorBody)
        restingRect = ArtRect(monitor.midX - c.width / 2, max(layout.visible.minY + 3, monitor.minY - c.height - 3), c.width, c.height)
        node.texture = TextureFactory.texture(c.buffer)
        place(space)
    }

    func hide() {
        key = nil
        text = nil
        node.isHidden = true
        rect = nil
    }

    func step(_ dt: Double, space: ArtSpace) {
        guard text != nil else { return }
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
