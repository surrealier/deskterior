import AppKit
import DeskCore
import DeskFiles
import DeskScene

/// Files dragged onto the desk from Finder or another app (DESIGN §3.6 Drop-in). While the drag is over the desk,
/// the screen brackets the cell it would land in, and the drag source is told what will happen
/// (`DropIn.dragOperation`): nothing where the drop would bonk, a copy when any item lies on another volume (or with
/// ⌥), else a move, so a source that removes its own item after a move never does so for one we only copied. On the
/// drop, the scene says where they land (a screen cell, a hiding place, a desk pile at that spot, the floor), or
/// bonks (the screen is off, a container is full, a drive); the store gets one `requestDropIn`. Items already in
/// the desk folder only move on the desk; the others are moved in (same volume, `RENAME_EXCL`, " 2" on a clash) or
/// copied (another volume, or ⌥), by `FileOperator`, undoably, and land where they were dropped. The demo runner's
/// `dropIn` step comes through `drop` too.
final class DropInController {
    let host: SceneHost
    unowned let store: Store
    unowned let effects: EffectRunner

    init(host: SceneHost, store: Store, effects: EffectRunner) {
        self.host = host
        self.store = store
        self.effects = effects
    }

    // MARK: Dragging over the desk

    /// The drag the volume answer below belongs to (`NSDraggingInfo.draggingSequenceNumber`).
    private var volumesChecked: (drag: Int, crosses: Bool)?

    /// The operation a drag of `urls` at canvas `p` would get (`DropIn.dragOperation`; `copy`: ⌥, or a source that
    /// offers no move); the landing cell is bracketed. `drag` names the dragging session: its items' volumes are
    /// read once per drag.
    func dragged(_ urls: [URL], at p: SIMD2<Float>, copy: Bool, drag: Int) -> NSDragOperation {
        let s = store.state
        guard !urls.isEmpty, s.access == .connected, let root = s.root else {
            dragEnded()
            return []
        }
        if volumesChecked?.drag != drag {
            volumesChecked = (drag, Self.crossesVolumes(urls, desk: URL(fileURLWithPath: root.path, isDirectory: true)))
        }
        let bonks: Bool = if case .bonk = host.scene.fileDropVerdict(count: urls.count, at: p) { true } else { false }
        host.scene.showFileDropTarget(count: bonks ? 0 : urls.count, at: bonks ? nil : p)
        host.modelChanged()
        switch DropIn.dragOperation(bonks: bonks, forcedCopy: copy, crossesVolumes: volumesChecked?.crosses ?? true) {
        case .move?: return .move
        case .copy?: return .copy
        case nil: return []
        }
    }

    /// Whether any of `urls` lies on another volume than the desk folder (or its volume cannot be read): that item
    /// is copied in.
    static func crossesVolumes(_ urls: [URL], desk: URL) -> Bool {
        guard let deskVolume = FileOperator.volumeUUID(desk) else { return true }
        return urls.contains { FileOperator.volumeUUID($0) != deskVolume }
    }

    func dragEnded() {
        host.scene.showFileDropTarget(count: 0, at: nil)
        host.modelChanged()
    }

    // MARK: The drop

    /// Takes `urls` dropped at canvas `p`; true when they were taken (false: a bonk, or nothing to take).
    @discardableResult
    func drop(_ urls: [URL], at p: SIMD2<Float>, copy: Bool) -> Bool {
        dragEnded()
        let s = store.state
        guard s.access == .connected, let root = s.root else { return false }
        let files = urls.filter(\.isFileURL).map { Self.spelled($0, underRoot: root.path) }
        guard !files.isEmpty else { return false }
        switch host.scene.fileDropVerdict(count: files.count, at: p) {
        case let .bonk(reason):
            host.scene.bonkFileDrop(at: p, reason)
            host.modelChanged()
            return false
        case let .land(location, pilePos):
            let request = DropIn(urls: files, location: location, pilePos: pilePos, op: copy ? .copy : .move)
            effects.withOrigin(.drop) { store.dispatch(.requestDropIn(request)) }
            return true
        }
    }

    /// `url` spelled under the model's root when its folder is the desk folder by any spelling (symlinks, `/var`
    /// for `/private/var`, case), so the reducer sees it is on the desk already; otherwise as it came.
    static func spelled(_ url: URL, underRoot root: String) -> URL {
        let u = url.standardizedFileURL
        let parent = DesktopLocator.canonicalPath(u.deletingLastPathComponent())
        guard parent.lowercased() == DesktopLocator.canonicalPath(URL(fileURLWithPath: root)).lowercased() else { return u }
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(u.lastPathComponent, isDirectory: false)
    }

    /// File URLs on a dragging pasteboard.
    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Copy rather than move: ⌥ held, or a source that offers copying but not moving.
    static func wantsCopy(_ mask: NSDragOperation, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.option) || (!mask.contains(.move) && !mask.contains(.generic) && mask.contains(.copy))
    }
}
