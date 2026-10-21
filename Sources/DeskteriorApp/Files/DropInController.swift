import AppKit
import DeskCore
import DeskFiles
import DeskScene
import UniformTypeIdentifiers

/// Files dragged onto the desk from Finder or another app (DESIGN §3.6 Drop-in). While the drag is over the desk,
/// the screen brackets the cell it would land in, and the drag source is told what will happen
/// (`DropIn.dragOperation`, within what the source allows: `DropKeys.answer`): nothing where the drop would bonk, a
/// link when every item becomes an alias, a copy when any item stays where it is (copied, aliased, or on another
/// volume), else a move, so a source that removes its own item after a move never does so for one we only copied or
/// aliased. On the drop, the scene says where they land (a screen cell, a hiding place, a desk pile at that spot, the
/// floor), or bonks (the screen is off, a container is full, a drive); the store gets one `requestDropIn`. Items
/// already in the desk folder only move on the desk; the others come in by `FileOperator`, undoably, and land where
/// they were dropped, each as the keys held say (Erratum 29, `DropIn.ops`): with no key an application becomes an
/// alias (Finder's "put a shortcut to it there"; not one in a Trash or on a disk image, `staysInstalled`) and
/// anything else is moved in (same volume, `RENAME_EXCL`, " 2" on a clash) or copied (another volume); ⌥ copies
/// everything, ⌘ moves everything (apps too), ⌘⌥ makes an alias of everything. Walls answer and take drags the same
/// way. The demo runner's `dropIn` step comes through `drop` too. Over the picture frame (the desk's, or another
/// display's wall's) a drag is answered as for an alias, even one it will refuse, and its drop only reads one photo or
/// bonks with why; the drop goes where the drag's last answer said (Erratum 33).
final class DropInController {
    let host: SceneHost
    unowned let store: Store
    unowned let effects: EffectRunner
    // MARK: picture frame (0.4.0)
    /// Hangs a photo dropped on the picture frame (the session's loader).
    var hangPhoto: ((URL) -> Void)?
    /// Why a file dropped on the frame may not hang (the session's loader, with its real-Desktop guard; unguarded here).
    var photoRefusal: (URL) -> ToastKey? = { FramePhotoLoader.refusal($0, realDesktop: nil) }
    /// Whether the last answer of drag `drag` was the picture frame's (`dragged`), for its drop.
    private var frameDrag: (drag: Int, frame: Bool)?

    init(host: SceneHost, store: Store, effects: EffectRunner) {
        self.host = host
        self.store = store
        self.effects = effects
    }

    // MARK: Dragging over the desk

    /// What a drop needs to know of each dropped item, read from the items themselves.
    struct ItemFacts: Equatable {
        /// It lies on another volume than the desk folder (or its volume cannot be read).
        var crosses: [Bool]
        /// It is an application bundle (`FileOperator.isApplication`): its alias is named without ".app".
        var isApp: [Bool]
        /// It is an application that a drop with no key makes an alias of (`staysInstalled`).
        var aliasedWithNoKey: [Bool]
    }

    /// The drag the item facts below belong to (`NSDraggingInfo.draggingSequenceNumber`).
    private var itemsChecked: (drag: Int, facts: ItemFacts)?

    /// The operation a drag of `urls` at canvas `p` would get (`DropIn.dragOperation`; `copy`: ⌥, or a source that
    /// offers no move); the landing cell is bracketed. `drag` names the dragging session: its items' volumes and kinds
    /// are read once per drag. `keys`: the keys held and the operations the source allows (none given: ⌥ when
    /// `copy`, else no key, and every operation allowed).
    func dragged(_ urls: [URL], at p: SIMD2<Float>, copy: Bool, drag: Int, keys: DropKeys? = nil) -> NSDragOperation {
        // MARK: picture frame (0.4.0): over the frame a drop only reads one photo, whatever the folder (Erratum 33).
        let overFrame = host.scene.isOverPictureFrame(p)
        frameDrag = (drag, overFrame)
        if overFrame {
            host.scene.showFileDropTarget(count: 0, at: nil)
            host.modelChanged()
            return urls.isEmpty ? [] : Self.frameAnswer(keys ?? DropKeys(copy: copy))
        }
        let s = store.state
        guard !urls.isEmpty, s.access == .connected, let root = s.root else {
            dragEnded()
            return []
        }
        let facts = items(urls, drag: drag, root: root)
        let bonks: Bool = if case .bonk = host.scene.fileDropVerdict(count: urls.count, at: p) { true } else { false }
        host.scene.showFileDropTarget(count: bonks ? 0 : urls.count, at: bonks ? nil : p)
        host.modelChanged()
        return Self.answer(facts, copy: copy, keys: keys, bonks: bonks)
    }

    /// The facts of `urls` for drag `drag` (read once per drag).
    private func items(_ urls: [URL], drag: Int, root: DesktopRoot) -> ItemFacts {
        if let c = itemsChecked, c.drag == drag, c.facts.crosses.count == urls.count { return c.facts }
        let facts = Self.facts(urls, desk: URL(fileURLWithPath: root.path, isDirectory: true))
        itemsChecked = (drag, facts)
        return facts
    }

    /// The facts of `urls` dropped on the desk folder `desk` (nil: crossings are not asked for).
    static func facts(_ urls: [URL], desk: URL?) -> ItemFacts {
        let isApp = urls.map(isApplication)
        return ItemFacts(
            crosses: desk.map { crossings(urls, desk: $0) } ?? urls.map { _ in false }, isApp: isApp,
            aliasedWithNoKey: zip(urls, isApp).map { $1 && staysInstalled($0) }
        )
    }

    /// What a drag of items with `facts` is told (`DropIn.dragOperation`, as `DropKeys.answer` puts it to the
    /// source), with `copy` and `keys` as for `dragged`.
    static func answer(_ facts: ItemFacts, copy: Bool, keys: DropKeys?, bonks: Bool) -> NSDragOperation {
        let k = keys ?? DropKeys(copy: copy)
        let ops = ops(facts, copy: copy, keys: k)
        return k.answer(DropIn.dragOperation(bonks: bonks, ops: ops, crosses: facts.crosses))
    }

    /// The op of each item with `facts` (`DropIn.ops`): the keys held, and what the source allows (`canMove` from
    /// its mask as well as `copy`; a link-only source makes aliases).
    static func ops(_ facts: ItemFacts, copy: Bool, keys k: DropKeys) -> [ImportOp] {
        DropIn.ops(k.mode, isApp: facts.aliasedWithNoKey, canMove: !copy && k.canMove, canAlias: k.canAlias,
                   linkOnly: k.linkOnly)
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

    /// An application bundle (Erratum 29), directly or through a symbolic link (`FileOperator.isApplication`).
    static func isApplication(_ url: URL) -> Bool {
        FileOperator.isApplication(url)
    }

    /// Whether an app at `url` stays where it is installed, so a drop with no key makes an alias of it (Erratum 29).
    /// Not one in a Trash (dragged out, it comes back out as before) nor on a volume that comes and goes (a disk
    /// image, a USB stick or a card: ejectable, removable, or read-only other than the system's own), where an alias
    /// would break once the volume is gone. Such an app comes in as before: moved, or copied from another volume.
    static func staysInstalled(_ url: URL) -> Bool {
        guard !inTrash(url) else { return false }
        let keys: Set<URLResourceKey> = [
            .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
        ]
        guard let v = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: keys) else { return true }
        return !passingVolume(ejectable: v.volumeIsEjectable == true, removable: v.volumeIsRemovable == true,
                              readOnly: v.volumeIsReadOnly == true, system: v.volumeIsRootFileSystem == true)
    }

    /// The item lies in a Trash, by its path alone: the user's (`~/.Trash`), a volume's (`.Trashes/<uid>`) or
    /// iCloud Drive's (`.Trash`).
    static func inTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.dropLast().contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// A volume an app does not stay installed on: one that comes and goes (ejectable or removable: a disk image, a
    /// USB stick, a card) or that cannot be written other than the system's own (a read-only disk image).
    static func passingVolume(ejectable: Bool, removable: Bool, readOnly: Bool, system: Bool) -> Bool {
        ejectable || removable || (readOnly && !system)
    }

    func dragEnded() {
        host.scene.showFileDropTarget(count: 0, at: nil)
        host.modelChanged()
    }

    // MARK: The drop

    /// Takes `urls` dropped at canvas `p`; true when they were taken (false: a bonk, or nothing to take). `copy` and
    /// `keys` as for `dragged`; `drag` names the dragging session whose last answer decides a drop on or off the
    /// picture frame (nil: a demo's drop or a test, where the point decides; Erratum 33).
    @discardableResult
    func drop(_ urls: [URL], at p: SIMD2<Float>, copy: Bool, keys: DropKeys? = nil, drag: Int? = nil) -> Bool {
        dragEnded()
        // MARK: picture frame (0.4.0): the drop goes where this drag's last answer said (Erratum 33).
        let answered = drag.flatMap { d in frameDrag.flatMap { $0.drag == d ? $0.frame : nil } }
        frameDrag = nil
        switch Self.frameRoute(answeredFrame: answered, overFrame: host.scene.isOverPictureFrame(p)) {
        case .frame:
            return takeForFrame(urls, bonkAt: p)
        case .refuse:
            host.scene.bonkFileDrop(at: p, nil)
            host.modelChanged()
            return false
        case .desk:
            break
        }
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
            let request = Self.request(files, location: location, pilePos: pilePos, copy: copy, keys: keys)
            effects.withOrigin(.drop) { store.dispatch(.requestDropIn(request)) }
            return true
        }
    }

    // MARK: picture frame (0.4.0)

    /// Where a Finder drop goes (Erratum 33).
    enum FrameRoute: Equatable { case frame, desk, refuse }

    /// As the drag's last answer said: told the frame's answer, the drop is the frame's (it only reads) wherever it is
    /// let go; told the desk's (perhaps a move), a drop let go over the frame is refused (nothing is read for a source
    /// that may remove its item after a move, and nothing is imported onto the photo); with no answer remembered (a
    /// demo's drop, a test), the point decides.
    static func frameRoute(answeredFrame: Bool?, overFrame: Bool) -> FrameRoute {
        switch answeredFrame {
        case true?: .frame
        case false?: overFrame ? .refuse : .desk
        case nil: overFrame ? .frame : .desk
        }
    }

    /// A drop on the picture frame (Erratum 33): one photo is read for it and stays where it is (never a file request,
    /// so nothing is moved, copied or imported, and no connected folder is needed); anything else bonks at `p` with why
    /// (with no point — a wall — the desk toasts why). True when a photo is being hung.
    private func takeForFrame(_ urls: [URL], bonkAt p: SIMD2<Float>?) -> Bool {
        let files = urls.filter(\.isFileURL)
        if let refusal = frameRefusal(files) {
            if let p { host.scene.bonkFileDrop(at: p, refusal) } else { host.scene.toast(refusal) }
            host.modelChanged()
            return false
        }
        guard let hangPhoto else { return false }
        hangPhoto(files[0])
        return true
    }

    /// Why `urls` cannot hang in the frame: none → "That isn't a photo."; several → "One photo at a time."; else
    /// `photoRefusal` of the one (read on the main thread: resource values only).
    func frameRefusal(_ urls: [URL]) -> ToastKey? {
        guard urls.count == 1, let url = urls.first else { return urls.isEmpty ? .notAPhoto : .onePhotoAtATime }
        return photoRefusal(url)
    }

    /// What a drag over the frame is told: the item stays where it is, so never a move — a link, else a copy, else a
    /// generic drop, the first the source allows (Erratum 29's alias answers); nothing when it allows none of them (a
    /// move-only source: its drop is never delivered, so nothing is said).
    static func frameAnswer(_ keys: DropKeys) -> NSDragOperation {
        [NSDragOperation.link, .copy, .generic].first(where: keys.mask.contains) ?? []
    }

    /// The op of each dropped item (`DropIn.ops`), read from the items at the drop.
    static func ops(_ files: [URL], copy: Bool, keys: DropKeys?) -> [ImportOp] {
        ops(facts(files, desk: nil), copy: copy, keys: keys ?? DropKeys(copy: copy))
    }

    /// The request for `files` dropped at `location`: each item's op, and which are applications (read from the
    /// items at the drop).
    private static func request(
        _ files: [URL], location: Location, pilePos: SIMD2<Float>? = nil, copy: Bool, keys: DropKeys?
    ) -> DropIn {
        let f = facts(files, desk: nil)
        return DropIn(urls: files, location: location, pilePos: pilePos,
                      ops: ops(f, copy: copy, keys: keys ?? DropKeys(copy: copy)), apps: f.isApp)
    }

    // MARK: Walls (M12)

    /// The operation a wall answers a drag of `urls` with: as over the desk, without a landing to bracket (they go to
    /// the monitor's first free cell), nothing while the desk folder is not connected.
    func wallOperation(_ urls: [URL], copy: Bool, drag: Int, keys: DropKeys? = nil) -> NSDragOperation {
        let s = store.state
        guard !urls.isEmpty, s.access == .connected, let root = s.root else { return [] }
        return Self.answer(items(urls, drag: drag, root: root), copy: copy, keys: keys, bonks: false)
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
        let request = Self.request(files, location: cell.location, copy: copy, keys: keys)
        effects.withOrigin(.drop) { store.dispatch(.requestDropIn(request)) }
        return true
    }

    // MARK: picture frame (0.4.0)

    /// What a wall answers a drag over its own picture frame with (Erratum 33): as over the desk's frame, connected or not.
    func wallFrameOperation(_ urls: [URL], keys: DropKeys) -> NSDragOperation {
        urls.isEmpty ? [] : Self.frameAnswer(keys)
    }

    /// A drop on a wall's picture frame (Erratum 33): as on the desk's, never `dropOnWall`'s import; the desk toasts a
    /// refusal (the wall has no bonk to show).
    @discardableResult
    func dropOnWallFrame(_ urls: [URL]) -> Bool { takeForFrame(urls, bonkAt: nil) }

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

    /// The source lets its item be moved: it allows a move, or a generic drop (AppKit narrows the mask to that
    /// while ⌘ is held).
    var canMove: Bool { !mask.intersection([.move, .generic]).isEmpty }

    /// The source lets us leave its item where it is (it allows a link, a copy or a generic drop), so an alias can
    /// be its answer.
    var canAlias: Bool { !mask.intersection([.link, .copy, .generic]).isEmpty }

    /// The source allows nothing but a link (AppKit narrows the mask to that while ⌃ is held): every item becomes
    /// an alias.
    var linkOnly: Bool { mask.contains(.link) && mask.intersection([.move, .copy, .generic]).isEmpty }

    /// The answer to the drag source for `op` (`DropIn.dragOperation`), the first of these the source allows: for
    /// aliases a link, else a copy, else a generic drop (each leaves its item where it is); for a copy a copy, else
    /// a generic drop (AppKit narrows the mask to that while ⌘ is held); for a move a move, else a generic drop.
    /// When the source allows none of them, the first (as before). Nothing where it bonks, or when the source
    /// allows no move, copy, link or generic drop at all.
    func answer(_ op: ImportOp?) -> NSDragOperation {
        guard !mask.intersection([.move, .copy, .link, .generic]).isEmpty else { return [] }
        let wanted: [NSDragOperation] = switch op {
        case nil: []
        case .copy?: [.copy, .generic]
        case .move?: [.move, .generic]
        case .alias?: [.link, .copy, .generic]
        }
        return wanted.first(where: mask.contains) ?? wanted.first ?? []
    }
}
