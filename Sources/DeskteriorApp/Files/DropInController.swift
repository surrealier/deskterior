import AppKit
import DeskCore
import DeskFiles
import DeskScene

/// Files dragged onto the desk from Finder or another app (DESIGN §3.6 Drop-in). While the drag is over the desk,
/// the screen brackets the cell it would land in. On the drop, the scene says where they land (a screen cell, a
/// hiding place, a desk pile at that spot, the floor), or bonks (the screen is off, a container is full, a drive);
/// the store gets one `requestDropIn`. Items already in the desk folder only move on the desk; the others are moved
/// in (same volume, `RENAME_EXCL`, " 2" on a clash) or copied (another volume, or ⌥), by `FileOperator`, undoably,
/// and land where they were dropped. The demo runner's `dropIn` step comes through `drop` too.
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

    /// The operation a drag of `count` files at canvas `p` would get (copy with ⌥ or when the source allows only
    /// copying); the landing cell is bracketed.
    func dragged(count: Int, at p: SIMD2<Float>, copy: Bool) -> NSDragOperation {
        guard count > 0, store.state.access == .connected else { return [] }
        host.scene.showFileDropTarget(count: count, at: p)
        host.modelChanged()
        return copy ? .copy : .move
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
