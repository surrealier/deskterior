import AppKit
import DeskCore
import DeskFiles
import DeskScene
import UniformTypeIdentifiers

/// Files dragged onto the desk from Finder or another app (DESIGN §3.6 Drop-in). While the drag is over the desk,
/// the screen brackets the cell it would land in, and the drag source is told what will happen
/// (`DropIn.dragOperation`): nothing where the drop would bonk, a link when every item becomes an alias, a copy when
/// any item is copied or lies on another volume (or with ⌥), else a move, so a source that removes its own item after
/// a move never does so for one we only copied or aliased. On the drop, the scene says where they land (a screen
/// cell, a hiding place, a desk pile at that spot, the floor), or bonks (the screen is off, a container is full, a
/// drive); the store gets one `requestDropIn`. Items already in the desk folder only move on the desk; the others
/// come in by `FileOperator`, undoably, and land where they were dropped, each as the keys held say (Erratum 29,
/// `DropIn.ops`): with no key an application becomes an alias (Finder's "put a shortcut to it there") and anything
/// else is moved in (same volume, `RENAME_EXCL`, " 2" on a clash) or copied (another volume); ⌥ copies everything,
/// ⌘ moves everything (apps too), ⌘⌥ makes an alias of everything. The demo runner's `dropIn` step comes through
/// `drop` too.
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

    /// The drag the item facts below belong to (`NSDraggingInfo.draggingSequenceNumber`): for each item, whether it
    /// lies on another volume than the desk folder and whether it is an application.
    private var itemsChecked: (drag: Int, crosses: [Bool], isApp: [Bool])?

    /// The operation a drag of `urls` at canvas `p` would get (`DropIn.dragOperation`; `copy`: ⌥, or a source that
    /// offers no move); the landing cell is bracketed. `drag` names the dragging session: its items' volumes and kinds
    /// are read once per drag. `keys`: the keys held and the operations the source allows (none given: ⌥ when
    /// `copy`, else no key, and every operation allowed).
    func dragged(_ urls: [URL], at p: SIMD2<Float>, copy: Bool, drag: Int, keys: DropKeys? = nil) -> NSDragOperation {
        let s = store.state
        guard !urls.isEmpty, s.access == .connected, let root = s.root else {
            dragEnded()
            return []
        }
        let facts = items(urls, drag: drag, root: root)
        let bonks: Bool = if case .bonk = host.scene.fileDropVerdict(count: urls.count, at: p) { true } else { false }
        host.scene.showFileDropTarget(count: bonks ? 0 : urls.count, at: bonks ? nil : p)
        host.modelChanged()
        let k = keys ?? DropKeys(copy: copy)
        let ops = DropIn.ops(k.mode, isApp: facts.isApp, canMove: !copy, canAlias: k.canAlias)
        return k.answer(DropIn.dragOperation(bonks: bonks, ops: ops, crosses: facts.crosses))
    }

    /// The facts of `urls` for drag `drag` (read once per drag).
    private func items(_ urls: [URL], drag: Int, root: DesktopRoot) -> (crosses: [Bool], isApp: [Bool]) {
        if let c = itemsChecked, c.drag == drag, c.crosses.count == urls.count { return (c.crosses, c.isApp) }
        let desk = URL(fileURLWithPath: root.path, isDirectory: true)
        let facts = (crosses: Self.crossings(urls, desk: desk), isApp: urls.map(Self.isApplication))
        itemsChecked = (drag, facts.crosses, facts.isApp)
        return facts
    }

    /// Whether any of `urls` lies on another volume than the desk folder (or its volume cannot be read): that item
    /// is copied in.
    static func crossesVolumes(_ urls: [URL], desk: URL) -> Bool {
        crossings(urls, desk: desk).contains(true)
    }

    /// For each of `urls`, whether it lies on another volume than the desk folder (or a volume cannot be read).
    static func crossings(_ urls: [URL], desk: URL) -> [Bool] {
        guard let deskVolume = FileOperator.volumeUUID(desk) else { return urls.map { _ in true } }
        return urls.map { FileOperator.volumeUUID($0) != deskVolume }
    }

    /// An application bundle (Erratum 29): a folder whose type is an application (`UTType.application`), or a
    /// package named ".app". Reads resource values only; a symbolic link to an app is not one (the link moves).
    static func isApplication(_ url: URL) -> Bool {
        guard url.isFileURL,
              let v = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]),
              v.isSymbolicLink != true, v.isDirectory == true
        else { return false }
        if v.contentType?.conforms(to: .application) == true { return true }
        return v.isPackage == true && url.pathExtension.lowercased() == "app"
    }

    func dragEnded() {
        host.scene.showFileDropTarget(count: 0, at: nil)
        host.modelChanged()
    }

    // MARK: The drop

    /// Takes `urls` dropped at canvas `p`; true when they were taken (false: a bonk, or nothing to take). `copy` and
    /// `keys` as for `dragged`.
    @discardableResult
    func drop(_ urls: [URL], at p: SIMD2<Float>, copy: Bool, keys: DropKeys? = nil) -> Bool {
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
            let ops = Self.ops(files, copy: copy, keys: keys)
            let request = DropIn(urls: files, location: location, pilePos: pilePos, ops: ops)
            effects.withOrigin(.drop) { store.dispatch(.requestDropIn(request)) }
            return true
        }
    }

    /// The op of each dropped item (`DropIn.ops`), read from the items at the drop.
    static func ops(_ files: [URL], copy: Bool, keys: DropKeys?) -> [ImportOp] {
        let k = keys ?? DropKeys(copy: copy)
        return DropIn.ops(k.mode, isApp: files.map(isApplication), canMove: !copy, canAlias: k.canAlias)
    }

    // MARK: Walls (M12)

    /// The operation a wall answers a drag of `urls` with: as over the desk, without a landing to bracket (they go to
    /// the monitor's first free cell), nothing while the desk folder is not connected.
    func wallOperation(_ urls: [URL], copy: Bool, drag: Int, keys: DropKeys? = nil) -> NSDragOperation {
        let s = store.state
        guard !urls.isEmpty, s.access == .connected, let root = s.root else { return [] }
        let facts = items(urls, drag: drag, root: root)
        let k = keys ?? DropKeys(copy: copy)
        let ops = DropIn.ops(k.mode, isApp: facts.isApp, canMove: !copy, canAlias: k.canAlias)
        return k.answer(DropIn.dragOperation(bonks: false, ops: ops, crosses: facts.crosses))
    }

    /// Takes `urls` dropped on a wall (another display): they land on the monitor's first free cell (DESIGN §4.10)
    /// through the same request, and the same undo, as a drop on the desk.
    @discardableResult
    func dropOnWall(_ urls: [URL], copy: Bool, keys: DropKeys? = nil) -> Bool {
        let s = store.state
        guard s.access == .connected, let root = s.root else { return false }
        let files = urls.filter(\.isFileURL).map { Self.spelled($0, underRoot: root.path) }
        guard !files.isEmpty else { return false }
        let cell = ScreenGrid.standard.firstFree(s.tokens.occupiedCells)
        let request = DropIn(urls: files, location: cell.location, ops: Self.ops(files, copy: copy, keys: keys))
        effects.withOrigin(.drop) { store.dispatch(.requestDropIn(request)) }
        return true
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

// MARK: - alias (Erratum 29)

/// What a file drag carries besides its files: the keys held over it (`DropMode`: none, ⌥, ⌘ or ⌘⌥) and the
/// operations its source allows (`NSDraggingInfo.draggingSourceOperationMask`).
struct DropKeys: Equatable {
    var mode: DropMode
    var mask: NSDragOperation

    init(mode: DropMode = .standard, mask: NSDragOperation = .every) {
        self.mode = mode
        self.mask = mask
    }

    /// The keys of `modifiers` (⌥ and ⌘; others are ignored) over a source allowing `mask`.
    init(modifiers: NSEvent.ModifierFlags, mask: NSDragOperation) {
        self.init(mode: DropMode(option: modifiers.contains(.option), command: modifiers.contains(.command)), mask: mask)
    }

    /// What a caller that only says "copy" asks for: ⌥ when `copy`, else no key; every operation allowed.
    init(copy: Bool) {
        self.init(mode: copy ? .copy : .standard)
    }

    /// The source lets us leave its item where it is (it allows a link, a copy or a generic drop), so an alias can
    /// be its answer.
    var canAlias: Bool { !mask.intersection([.link, .copy, .generic]).isEmpty }

    /// The answer to the drag source for `op` (`DropIn.dragOperation`): a link for aliases (or the copy, else the
    /// generic drop, the source allows: each leaves its item where it is), a copy, a move (or the generic drop when
    /// the source allows no move, as AppKit narrows the mask while ⌘ is held), nothing where it bonks.
    func answer(_ op: ImportOp?) -> NSDragOperation {
        switch op {
        case nil: []
        case .copy?: .copy
        case .move?: mask.contains(.move) || !mask.contains(.generic) ? .move : .generic
        case .alias?: mask.contains(.link) ? .link : mask.contains(.copy) ? .copy : .generic
        }
    }
}
