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
        case .dropHoldsDesk: "Can't drop the Desktop or a parent folder."
        case .ejectFailed: "The drive could not be ejected."
        case .nameTaken: "Too many items with that name."
        case .someChanged: "Some changed on disk, so they stayed."
        case .someGone: "Some were gone already."
        case .someNotPermitted: "macOS kept some items where they were."
        case .dropWholeDrive: "Drag files from the drive, not the drive."
        case .filesUnavailable: "The desk isn't connected to its folder."
        case .nothingToUndo: "Nothing to undo: those items are gone."
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
        case .leftoverCopies: "Interrupted copy left files. See Settings."
        case .someLocked: "Some were locked, so they stayed."
        case .someCopiedInstead: "Some came in as copies; the rest stayed."
        case .copiedNoUndo: "Copied in, but it can't be undone."
        // MARK: alias (Erratum 29)
        case .aliasMade: "Made an alias; the app stayed put."
        case .aliasesMade: "Made aliases; the apps stayed put."
        case .aliasMadeOriginal: "Made an alias; the original stayed put."
        case .aliasesMadeOriginals: "Made aliases; the originals stayed put."
        case .appAliasedRestIn: "The app became an alias; the rest came in."
        case .appsAliasedRestIn: "Apps became aliases; the rest came in."
        case .aliasNoUndo: "Made an alias, but it can't be undone."
        case .undidAlias: "The alias went to the Trash."
        case .undidAliases: "The aliases went to the Trash."
        case .undidAliasMix: "Undone; the alias went to the Trash."
        case .undidAliasesMix: "Undone; the aliases went to the Trash."
        // MARK: tidy (0.3.0)
        case .putAwayPlace: "That's put away."
        case .tookFilesOut: "Took the files out first."
        case .drawersPutAway: "The drawers are put away."
        case .madeRoom: "Moved things aside to make room."
        // MARK: memos (0.3.0)
        case .partitionFull: "The partition is full."
        case .memoClipsFull: "The memo clips are full."
        case .noteRemoved: "Note taken off."
        case .savedTextFile: "Saved as a text file."
        case .undidSaveTextFile: "The text file went to the Trash."
        }
    }

    /// The toast text in the current language.
    public var text: String { L10n.tr(english) }

    /// The toast text in `language`.
    public func text(_ language: Language) -> String { L10n.tr(english, language) }
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

    /// The toast's tab for `line`: the shadowed text on a dark tab with a walnut rim.
    static func image(_ line: String, font: PixelFont) -> PixelBuffer {
        let text = PixelText.shadowed(line, .neutral9, shadow: .neutral0, font: font)
        let w = text.width + 10, h = text.height + 6
        var c = PixelCanvas(width: w, height: h + 1)
        c.roundedRectFill(ArtRect(0, 1, w, h), radius: 2, .neutral0)
        c.roundedRectFill(ArtRect(0, 0, w, h), radius: 2, .walnut4)
        c.roundedRectFill(ArtRect(1, 1, w - 2, h - 2), radius: 1, .neutral1)
        c.blit(text, at: ArtPoint(5, 3))
        return c.buffer
    }

    // MARK: w6-polish
    /// The span of wall a toast may take (core x): between the wall clock and the calendar, centred on the monitor
    /// it hangs over (232 px). It lies inside the visible band of the smallest canvas, and every toast's tab in either
    /// language fits it (`KoreanFitTests`).
    static let band: Range<Int> = {
        let mid = CoreLayout.monitorBody.midX
        let half = min(mid - CoreLayout.clock.maxX, CoreLayout.calendar.minX - mid)
        return (mid - half)..<(mid + half)
    }()

    private func render(_ line: String, font: PixelFont?, layout: SceneLayout, space: ArtSpace, inPlace: Bool) {
        guard let font else { return }
        let tab = Self.image(line, font: font)
        image = tab
        key = nil
        self.text = line
        age = inPlace ? min(age, Self.slide) : 0
        // On the wall just above the monitor (over its top edge when the wall is short).
        let monitor = layout.rect(CoreLayout.monitorBody)
        restingRect = ArtRect(monitor.midX - tab.width / 2, max(layout.visible.minY + 3, monitor.minY - tab.height - 3),
                              tab.width, tab.height)
        node.texture = TextureFactory.texture(tab)
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
