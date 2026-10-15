import AppKit
import DeskCore
import Foundation

// MARK: Results

/// Why a file action did not happen. Nothing was changed for that item.
public enum FileRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    /// The intent is older than `ExplicitIntent.maxAge`, or from the future.
    case staleIntent
    /// The intent was spent by an earlier request, or was never issued (a copied or forged value).
    case spentIntent
    /// The intent's origin does not fit the request (a drop cannot trash, an undo cannot import).
    case wrongOrigin
    /// Undo: this operator did not issue the record, or it was replayed already.
    case unknownRecord
    /// The request's task was cancelled; a copy cut short leaves nothing behind.
    case cancelled
    /// Demo and test modes: a path, the desktop folder or the trash lies outside every sandbox root.
    case outsideSandbox
    /// Not a direct child of the desktop folder.
    case outsideRoot
    /// Undo: the item is not directly inside our trash, or the trash never said where it went.
    case notInTrash
    /// Nothing is there now.
    case missing
    /// The item there is not the one the token stands for (volume or inode differ), right before acting or, when
    /// it was swapped in between, right after (it is put straight back then).
    case identityChanged
    /// `trash` got a different number of URLs and expected identities.
    case mismatchedRequest
    /// A drop of the desktop folder itself, or of a folder that contains it.
    case containsDesktop
    /// A drop of a whole volume.
    case volumeRoot
    /// An eject of something that is not an ejectable volume.
    case notEjectable
    /// "name", "name 2" … are all taken.
    case noFreeName
    /// The system said no (EPERM/EACCES: privacy protection, S11/S12).
    case notPermitted
    // MARK: harden
    /// A drop-in move of a Finder-locked item (or one in a locked folder): it is not copied instead, so a move never
    /// leaves a silent duplicate (Errata 25); ⌥ copies it on purpose.
    case locked
    /// A drop-in copy landed, but the item now at its name is not provably the one staged (another item was swapped
    /// in at once, or the volume numbers items by where they are: an empty file on FAT, some network shares). It is
    /// left there, untouched, and has no undo step.
    case landedUnverified
    /// Any other failure: an errno, or a Cocoa error code.
    case failed(Int)

    public var description: String {
        switch self {
        case .staleIntent: "stale-intent"
        case .spentIntent: "spent-intent"
        case .wrongOrigin: "wrong-origin"
        case .unknownRecord: "unknown-record"
        case .cancelled: "cancelled"
        case .outsideSandbox: "outside-sandbox"
        case .outsideRoot: "outside-root"
        case .notInTrash: "not-in-trash"
        case .missing: "missing"
        case .identityChanged: "identity-changed"
        case .mismatchedRequest: "mismatched-request"
        case .containsDesktop: "contains-desktop"
        case .volumeRoot: "volume-root"
        case .notEjectable: "not-ejectable"
        case .noFreeName: "no-free-name"
        case .notPermitted: "not-permitted"
        case .locked: "locked"
        case .landedUnverified: "landed-unverified"
        case let .failed(code): "failed(\(code))"
        }
    }

    static func from(errno e: Int32) -> FileRefusal {
        switch e {
        case EPERM, EACCES: .notPermitted
        case ENOENT, ENOTDIR: .missing
        default: .failed(Int(e))
        }
    }

    static func from(_ error: Error) -> FileRefusal {
        if let r = error as? FileRefusal { return r }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return from(errno: Int32(ns.code)) }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain {
            return from(errno: Int32(u.code))
        }
        if ns.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: ns.code) {
            case .fileReadNoPermission, .fileWriteNoPermission: return .notPermitted
            case .fileNoSuchFile, .fileReadNoSuchFile: return .missing
            default: break
            }
        }
        return .failed(ns.code)
    }
}

/// What happened to one item.
public enum FileOutcome: Sendable, Equatable {
    /// Moved to the trash; `to` is where it went, when the trash says.
    case trashed(URL, to: URL?)
    /// Renamed to `to` under the name asked for (a drop-in move, or an undo).
    case moved(URL, to: URL)
    /// Copied to `to` under the name asked for (a cross-volume or ⌥ drop, or a move the system refused).
    case copied(URL, to: URL)
    /// Moved, copied or aliased to `to` under a free Finder-style name ("name 2") because the name asked for was taken.
    case renamed(URL, to: URL, op: ImportOp)
    // MARK: alias (Erratum 29)
    /// A Finder alias of the item was made at `to` (an app's under its name without ".app"); the item is untouched.
    case aliased(URL, to: URL)
    /// Already a direct child of the desktop folder: placement only, no file change.
    case unchanged(URL)
    case ejected(URL)
    case refused(URL, FileRefusal)

    /// The URL the request named.
    public var source: URL {
        switch self {
        case let .trashed(u, _), let .moved(u, _), let .copied(u, _), let .renamed(u, _, _), let .unchanged(u),
             let .ejected(u), let .refused(u, _), let .aliased(u, _):
            u
        }
    }

    /// Where the item is now, when it moved.
    public var destination: URL? {
        switch self {
        case let .trashed(_, to): to
        case let .moved(_, to), let .copied(_, to), let .renamed(_, to, _), let .aliased(_, to): to
        case .unchanged, .ejected, .refused: nil
        }
    }

    public var refusal: FileRefusal? {
        if case let .refused(_, r) = self { return r }
        return nil
    }

    var logOutcome: String {
        switch self {
        case .renamed: "renamed"
        case .unchanged: "unchanged"
        case let .refused(_, r): "refused: \(r)"
        case .trashed, .moved, .copied, .ejected, .aliased: "ok"
        }
    }
}

/// The outcome of a trash, import or undo, item by item, in request order (undo: in the order it ran).
public struct FileResult: Sendable, Equatable {
    public var outcomes: [FileOutcome]
    /// How to take back what changed; nil when nothing did (and always nil for an undo).
    public var undo: FileUndoRecord?

    public init(outcomes: [FileOutcome], undo: FileUndoRecord?) {
        self.outcomes = outcomes
        self.undo = undo
    }

    public var refusals: [FileRefusal] { outcomes.compactMap(\.refusal) }
}

// MARK: FileOperator

/// The only code that changes user files (DESIGN §3.5–§3.7). Every mutating method spends a fresh
/// `ExplicitIntent` whose origin fits it and, item by item:
/// - confines targets to direct children of the realpath'd desktop folder (drop sources and trash URLs are the
///   only exceptions), and in demo and test modes every path to `sandboxRoots`;
/// - re-stats the item right before acting and refuses when its volume or inode is not the expected one, and
///   checks again right after: an item swapped in between is put straight back and refused;
/// - renames with `renamex_np(RENAME_EXCL)`, so nothing is ever replaced: a taken name becomes "name 2" … "name 100";
/// - trashes, never deletes. The only removal is of its own staging folders for copies and aliases;
/// - never changes a drop's source when it makes an alias of it (Erratum 29): it only reads it;
/// - logs the outcome to `OperationLog`.
/// Undo replays only records this operator issued, once each.
public actor FileOperator {
    /// Where trashed items go.
    public enum Trash: Sendable {
        /// The real Trash, through `NSWorkspace.recycle` (desk mode; refused in demo and test modes).
        case system
        /// A folder of our own (demo, headless and test modes). It must lie outside the desktop folder and the
        /// mirrored folder, and in demo and test modes inside a sandbox root.
        case folder(URL)
    }

    /// How far a drop-in copy has got.
    public struct CopyProgress: Sendable, Equatable {
        /// The dropped item, as the request named it.
        public var source: URL
        /// Files and folders started so far, the dropped item itself included.
        public var items: Int
    }

    /// The user actions each request answers to.
    enum Method {
        case trash, importItems, undo, eject

        var origins: Set<ExplicitIntent.Origin> {
            switch self {
            case .trash: [.menuItem, .sheetConfirm, .dragToTrash, .inventory]
            case .importItems: [.drop]
            case .undo: [.undo]
            case .eject: [.menuItem, .inventory]
            }
        }
    }

    /// The realpath'd desktop folder.
    public nonisolated let root: URL
    private let trasher: any Trasher
    private let log: OperationLog
    private let sandboxRoots: [String]?
    private let clock: @Sendable () -> Date
    private let uptime: @Sendable () -> ContinuousClock.Instant
    private let volumeID: @Sendable (URL) -> String?
    private var hooks = Hooks()
    /// Undo records issued and not replayed yet, oldest first.
    private var openRecords: [FileUndoRecord] = []
    static let maxOpenRecords = 256
    /// Staging folders of this operator's copies in flight: the only folders it ever removes. They are also listed
    /// process-wide (`PartialCopies.inFlight`), so no operator trashes, and no look reports, another's live copy.
    private var stagings: Set<String> = []

    /// Test seams for races.
    struct Hooks: Sendable {
        /// Runs right before every final rename, with the destination it is about to try.
        var beforeRename: (@Sendable (URL) -> Void)?
        /// Runs right before the time-of-check re-stat of an item.
        var beforeCheck: (@Sendable (URL) -> Void)?
        /// Runs right after a copy finishes (or an alias file is written), with the staged copy or alias.
        var afterCopy: (@Sendable (URL) -> Void)?
        // MARK: harden
        /// Runs right after a copy's final rename, with where it landed.
        var afterPlace: (@Sendable (URL) -> Void)?
        /// Stages copies in a hidden `.deskterior-partial-<uuid>` folder in the desk folder, as when the system
        /// offers no item-replacement folder on the desk's volume.
        var stageInDesk = false
        /// Stand-ins for the volume checks and the unmount itself (an eject in tests, which never reach a volume).
        var ejectable: (@Sendable (URL) -> Bool)?
        var unmount: (@Sendable (URL) throws -> Void)?
    }

    /// `sandboxRoots` is non-nil in demo, headless and test modes: then every path touched (the desktop folder,
    /// drop sources, undo destinations, the trash folder) must lie inside one of them, the system Trash is never
    /// used and nothing is ejected. Throws when a trash folder lies inside the desktop or the mirrored folder.
    public init(root: URL, trash: Trash, log: OperationLog, sandboxRoots: [URL]?) throws {
        let trasher: any Trasher
        switch trash {
        case .system: trasher = SystemTrasher()
        case let .folder(folder): trasher = try FakeTrasher(folder: folder, mirrored: root)
        }
        self.init(root: root, trasher: trasher, log: log, sandboxRoots: sandboxRoots)
    }

    /// `clock` stamps log lines, `uptime` measures intent freshness, and `volumeID` names an item's volume
    /// (`TokenKey.volume`; same volume = move).
    init(
        root: URL, trasher: any Trasher, log: OperationLog, sandboxRoots: [URL]?,
        clock: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        volumeID: @escaping @Sendable (URL) -> String? = FileOperator.volumeUUID
    ) {
        self.root = URL(fileURLWithPath: DesktopLocator.canonicalPath(root), isDirectory: true)
        self.trasher = trasher
        self.log = log
        self.sandboxRoots = sandboxRoots?.map { DesktopLocator.canonicalPath($0) }
        self.clock = clock
        self.uptime = uptime
        self.volumeID = volumeID
    }

    func setHooks(_ h: Hooks) { hooks = h }

    /// `URLResourceValues.volumeUUIDString`, read fresh (never from a URL's cache).
    public static func volumeUUID(_ url: URL) -> String? {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    // MARK: Trash

    /// Moves each `urls[i]` to the trash if it is still `expecting[i]`. Takes a `.menuItem`, `.sheetConfirm`,
    /// `.dragToTrash` or `.inventory` intent.
    public func trash(_ urls: [URL], expecting: [TokenKey], _ intent: ExplicitIntent) async -> FileResult {
        if let r = refusal(for: intent, .trash) ?? (urls.count == expecting.count ? nil : .mismatchedRequest) {
            let inodes = urls.count == expecting.count ? expecting.map { [$0.inode] } : nil
            return refuseAll(urls, r, op: .trash, intent: intent, inodes: inodes)
        }
        var outcomes: [FileOutcome] = []
        var steps: [FileUndoRecord.Step] = []
        for (url, key) in zip(urls, expecting) {
            let (outcome, step) = await trashOne(url, expecting: key)
            outcomes.append(outcome)
            if let step { steps.append(step) }
            record(.trash, outcome, inodes: [key.inode], intent: intent)
        }
        return FileResult(outcomes: outcomes, undo: issue(.trash, steps))
    }

    private func trashOne(_ url: URL, expecting key: TokenKey) async -> (FileOutcome, FileUndoRecord.Step?) {
        if let r = trashRefusal() { return (.refused(url, r), nil) }
        guard let item = deskChild(url) else { return (.refused(url, .outsideRoot), nil) }
        // MARK: harden: a copy in flight stages here (this operator's or another's, after a folder switch); only a
        // leftover from an earlier run may go (`PartialCopies`).
        if PartialCopies.inFlight.contains(item) { return (.refused(url, .failed(Int(EBUSY))), nil) }
        if let r = check(item, is: key) { return (.refused(url, r), nil) }
        switch await trashChecked(item, is: key) {
        case let .success(trashed):
            return (.trashed(url, to: trashed), .putBack(trashed: trashed, original: item, key: key))
        case let .failure(r): return (.refused(url, r), nil)
        }
    }

    /// Trashes `item`, then checks the trash got the item expected.
    private func trashChecked(_ item: URL, is key: TokenKey) async -> Result<URL?, FileRefusal> {
        do {
            let trashed = try await trasher.trash(item)
            if let trashed, let r = verify(trashed, is: key, elseReturnTo: item) { return .failure(r) }
            return .success(trashed)
        } catch {
            return .failure(FileRefusal.from(error))
        }
    }

    // MARK: Import

    /// Brings dropped items into the desktop folder, each with `op`. Takes a `.drop` intent. Same volume and
    /// `.move`: renamed in. Otherwise (another volume, `.copy`, or a move the system refuses): copied into a staging
    /// folder on the desk's volume, off the actor so other requests go on meanwhile, then renamed into place.
    /// `.alias`: a Finder alias of the item is written there instead and renamed into place (Erratum 29); the item
    /// itself is only read. A source is never deleted. Folders and packages go as one unit. `progress` hears of each
    /// item a copy starts; cancelling the calling task stops a copy and refuses what is left as `.cancelled`.
    public func importItems(
        _ urls: [URL], op: ImportOp, _ intent: ExplicitIntent, progress: (@Sendable (CopyProgress) -> Void)? = nil
    ) async -> FileResult {
        await importItems(urls, ops: Array(repeating: op, count: urls.count), intent, progress: progress)
    }

    /// `importItems(_:op:_:progress:)` with an op per item (`ops[i]` for `urls[i]`; a drop of an app beside
    /// documents aliases the app and moves the rest, Erratum 29). A request whose counts differ is refused.
    public func importItems(
        _ urls: [URL], ops: [ImportOp], _ intent: ExplicitIntent, progress: (@Sendable (CopyProgress) -> Void)? = nil
    ) async -> FileResult {
        let mismatch: FileRefusal? = urls.count == ops.count ? nil : .mismatchedRequest
        if let r = refusal(for: intent, .importItems) ?? rootRefusal() ?? mismatch {
            return refuseAll(urls, r, op: Self.logOp(ImportOp.headline(ops)), intent: intent)
        }
        var outcomes: [FileOutcome] = []
        var steps: [FileUndoRecord.Step] = []
        for (url, op) in zip(urls, ops) {
            let (outcome, step, inodes) = Task.isCancelled
                ? (.refused(url, .cancelled), nil, [])
                : await importOne(url, op: op, progress: progress)
            outcomes.append(outcome)
            if let step { steps.append(step) }
            let done: ImportOp = switch outcome {
            case .copied, .renamed(_, _, .copy): .copy
            case .aliased, .renamed(_, _, .alias): .alias
            case .refused, .unchanged: op
            default: .move
            }
            record(Self.logOp(done), outcome, inodes: inodes, intent: intent)
        }
        return FileResult(outcomes: outcomes, undo: issue(.importItems, steps))
    }

    /// The log's name for an import done as `op`.
    private static func logOp(_ op: ImportOp) -> OperationLog.Entry.Op {
        switch op {
        case .move: .importMove
        case .copy: .importCopy
        case .alias: .importAlias
        }
    }

    private func importOne(
        _ url: URL, op: ImportOp, progress: (@Sendable (CopyProgress) -> Void)?
    ) async -> (FileOutcome, FileUndoRecord.Step?, [UInt64]) {
        let source = url.standardizedFileURL
        guard inSandbox(source) else { return (.refused(url, .outsideSandbox), nil, []) }
        if SafetyGuard.isDirectChild(source, of: root) || Self.sameItem(source.deletingLastPathComponent(), root) {
            return (.unchanged(url), nil, [])
        }
        let sourcePath = Self.parentResolvedPath(source)
        if root.path == sourcePath || root.path.hasPrefix(sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/")
            || holdsDesktop(source)
        {
            return (.refused(url, .containsDesktop), nil, [])
        }
        if SafetyGuard.isVolumeRoot(source) { return (.refused(url, .volumeRoot), nil, []) }
        hooks.beforeCheck?(source)
        let key: TokenKey
        switch identity(of: source) {
        case let .success(k): key = k
        case let .failure(r): return (.refused(url, r), nil, [])
        }
        let name = source.lastPathComponent
        let splits = FileMoves.splitsExtension(source)
        // MARK: alias (Erratum 29): the item stays where it is; only an alias file of it comes in.
        if op == .alias {
            // An app's alias has no extension left to keep apart ("Foo.Bar" from "Foo.Bar.app" numbers as "Foo.Bar 2").
            let aliasName = DropIn.aliasName(name)
            return aliasIn(url, from: source, name: aliasName, splitsExtension: aliasName == name && splits,
                           sourceKey: key)
        }
        let sourceVolume = volumeID(source)
        if op == .move, let sourceVolume, sourceVolume == volumeID(root) {
            switch FileMoves.renameToFreeName(source, in: root, name: name, splitsExtension: splits, before: hooks.beforeRename) {
            case let .success(placed):
                let back = URL(fileURLWithPath: sourcePath, isDirectory: false)
                if let r = verify(placed.url, is: key, elseReturnTo: back) { return (.refused(url, r), nil, [key.inode]) }
                let outcome: FileOutcome = placed.renamed ? .renamed(url, to: placed.url, op: .move) : .moved(url, to: placed.url)
                return (outcome, .moveBack(current: placed.url, source: back, key: key), [key.inode])
            case let .failure(.errno(e)) where (e == EPERM || e == EACCES) && Self.isLocked(source):
                // MARK: harden: a locked item stays put; a copy here would leave a silent duplicate (Errata 25).
                return (.refused(url, .locked), nil, [key.inode])
            case let .failure(.errno(e)) where e == EXDEV || e == EPERM || e == EACCES:
                break // Another volume after all, or a protected folder (S12): copy instead (the report says so).
            case let .failure(f):
                return (.refused(url, f.refusal), nil, [key.inode])
            }
        }
        return await copyIn(
            url, from: source, name: name, splitsExtension: splits, sourceInode: key.inode, progress: progress
        )
    }

    /// The folder (not a symlink to one) at `url` is the desktop folder or one of its ancestors, compared by device
    /// and inode, so no spelling (case, Unicode form, the /System/Volumes/Data firmlink) gets past it.
    private func holdsDesktop(_ url: URL) -> Bool {
        guard let item = Self.fileID(url, follow: false), item.isFolder else { return false }
        var dir = root
        while true {
            if let d = Self.fileID(dir, follow: true), d.dev == item.dev, d.ino == item.ino { return true }
            if dir.path == "/" { return false }
            dir = dir.deletingLastPathComponent()
        }
    }

    /// Copies into a fresh staging folder, then renames the copy into place. The staging folder goes in every
    /// case, so a failed or cancelled copy leaves nothing on the desk.
    private func copyIn(
        _ url: URL, from source: URL, name: String, splitsExtension: Bool, sourceInode: UInt64,
        progress: (@Sendable (CopyProgress) -> Void)?
    ) async -> (FileOutcome, FileUndoRecord.Step?, [UInt64]) {
        let staging: URL
        do {
            staging = try makeStaging()
        } catch {
            return (.refused(url, FileRefusal.from(error)), nil, [sourceInode])
        }
        defer { removeStaging(staging) }
        let staged = staging.appendingPathComponent(name, isDirectory: false)
        let report = progress.map { progress in { @Sendable (n: Int) in progress(CopyProgress(source: url, items: n)) } }
        do {
            try await Self.copy(source, to: staged, report: report)
        } catch {
            return (.refused(url, FileRefusal.from(error)), nil, [sourceInode])
        }
        hooks.afterCopy?(staged)
        let key: TokenKey
        switch identity(of: staged) {
        case let .success(k): key = k
        case let .failure(r): return (.refused(url, r), nil, [sourceInode])
        }
        // A Finder-locked item cannot be renamed: the copy is unlocked for the rename and locked again in place.
        let locks = Self.lockFlags(staged)
        if locks != 0 { Self.changeFlags(staged, adding: 0, removing: locks) }
        switch FileMoves.renameToFreeName(
            staged, in: root, name: name, splitsExtension: splitsExtension, before: hooks.beforeRename
        ) {
        case let .success(placed):
            // MARK: harden: success only for the copy we wrote; whatever else is there now is left alone.
            hooks.afterPlace?(placed.url)
            if let r = landed(placed.url, is: key) { return (.refused(url, r), nil, [sourceInode]) }
            if locks != 0 { Self.changeFlags(placed.url, adding: locks, removing: 0) }
            let outcome: FileOutcome = placed.renamed ? .renamed(url, to: placed.url, op: .copy) : .copied(url, to: placed.url)
            return (outcome, .trashCopy(placed.url, key: key), [sourceInode, key.inode])
        case let .failure(f):
            return (.refused(url, f.refusal), nil, [sourceInode])
        }
    }

    // MARK: alias (Erratum 29)

    /// Writes a Finder alias of `source` (bookmark data `suitableForBookmarkFile`) into a fresh staging folder, then
    /// renames it into place as `name`, or "name 2", "name 3"… on a clash (`RENAME_EXCL`), exactly like a copy. The
    /// source is only read: the alias names the item that was checked (one swapped in meanwhile is refused), and its
    /// landing is checked like a copy's (`landed`). The undo step trashes the alias, never what it points to.
    private func aliasIn(
        _ url: URL, from source: URL, name: String, splitsExtension: Bool, sourceKey: TokenKey
    ) -> (FileOutcome, FileUndoRecord.Step?, [UInt64]) {
        let staging: URL
        do {
            staging = try makeStaging()
        } catch {
            return (.refused(url, FileRefusal.from(error)), nil, [sourceKey.inode])
        }
        defer { removeStaging(staging) }
        let staged = staging.appendingPathComponent(name, isDirectory: false)
        do {
            let bookmark = try source.bookmarkData(
                options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil
            )
            try URL.writeBookmarkData(bookmark, to: staged)
        } catch {
            return (.refused(url, FileRefusal.from(error)), nil, [sourceKey.inode])
        }
        hooks.afterCopy?(staged)
        guard case let .success(now) = identity(of: source), now == sourceKey else {
            return (.refused(url, .identityChanged), nil, [sourceKey.inode])
        }
        let key: TokenKey
        switch identity(of: staged) {
        case let .success(k): key = k
        case let .failure(r): return (.refused(url, r), nil, [sourceKey.inode])
        }
        switch FileMoves.renameToFreeName(
            staged, in: root, name: name, splitsExtension: splitsExtension, before: hooks.beforeRename
        ) {
        case let .success(placed):
            hooks.afterPlace?(placed.url)
            if let r = landed(placed.url, is: key) { return (.refused(url, r), nil, [sourceKey.inode]) }
            let outcome: FileOutcome = placed.renamed
                ? .renamed(url, to: placed.url, op: .alias) : .aliased(url, to: placed.url)
            return (outcome, .trashAlias(placed.url, key: key), [sourceKey.inode, key.inode])
        case let .failure(f):
            return (.refused(url, f.refusal), nil, [sourceKey.inode])
        }
    }

    /// A new folder for one copy, on the desk's volume but outside the desk folder (the system's item-replacement
    /// folder), so a copy cut short by a quit or crash never shows on the desk. When the system offers none on that
    /// volume, a hidden `.deskterior-partial-<uuid>` folder in the desk folder stands in.
    private func makeStaging() throws -> URL {
        guard let desk = Self.fileID(root, follow: true) else { throw FileRefusal.missing }
        if !hooks.stageInDesk, let dir = try? FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: root, create: true
        ) {
            if Self.fileID(dir, follow: true)?.dev == desk.dev, !DesktopLocator.isInsideDesktop(dir, desktop: root) {
                stagings.insert(dir.path)
                PartialCopies.inFlight.insert(dir)
                return dir
            }
            _ = rmdir(dir.path) // Ours and still empty.
        }
        let dir = root.appendingPathComponent(FileMoves.partialPrefix + UUID().uuidString, isDirectory: true)
        guard mkdir(dir.path, 0o700) == 0 else { throw FileRefusal.from(errno: errno) }
        stagings.insert(dir.path)
        PartialCopies.inFlight.insert(dir)
        return dir
    }

    /// Removes one of our staging folders. When a plain removal fails (the copy brought read-only folders or
    /// Finder-locked files along), everything inside is unlocked and made writable first; symlinks are never
    /// followed.
    private func removeStaging(_ dir: URL) {
        guard stagings.remove(dir.path) != nil else { return }
        defer { PartialCopies.inFlight.remove(dir) }
        if (try? FileManager.default.removeItem(at: dir)) != nil { return }
        Self.unlockTree(dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private static func unlockTree(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        let locks = st.st_flags & lockMask
        if locks != 0 { _ = lchflags(path, st.st_flags & ~locks) }
        guard st.st_mode & S_IFMT == S_IFDIR else { return }
        if st.st_mode & S_IRWXU != S_IRWXU {
            _ = fchmodat(AT_FDCWD, path, (st.st_mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW)
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            unlockTree((path as NSString).appendingPathComponent(name))
        }
    }

    /// Finder's lock and the append-only flag (both stop a rename).
    private static let lockMask = UInt32(UF_IMMUTABLE | UF_APPEND)

    private static func lockFlags(_ url: URL) -> UInt32 {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st.st_flags & lockMask : 0
    }

    private static func changeFlags(_ url: URL, adding: UInt32, removing: UInt32) {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        _ = lchflags(url.path, (st.st_flags & ~removing) | adding)
    }

    // MARK: harden

    /// The item at `url` is locked (Finder's lock, append-only, or the system's), or its folder is, so it cannot be
    /// renamed out of there.
    static func isLocked(_ url: URL) -> Bool {
        var st = stat()
        let item = UInt32(UF_IMMUTABLE | UF_APPEND) | UInt32(SF_IMMUTABLE | SF_APPEND)
        if lstat(url.path, &st) == 0, st.st_flags & item != 0 { return true }
        let folder = url.standardizedFileURL.deletingLastPathComponent()
        return lstat(folder.path, &st) == 0 && st.st_flags & (UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)) != 0
    }

    /// After a copy's final rename: the item now at `placed` is the copy staged (its volume and inode), so it is
    /// ours, however it changed since (a sync client writing to it at once): its locks go back on and its undo step
    /// stands. Anything else (another item swapped in at once, or a volume that renumbers items on a rename) is not
    /// provably ours: it is left there, untouched, with no undo step (`landedUnverified`).
    private func landed(_ placed: URL, is key: TokenKey) -> FileRefusal? {
        if case let .success(found) = identity(of: placed), found == key { return nil }
        return .landedUnverified
    }

    /// Copies on a GCD thread, so the actor serves other requests meanwhile (DESIGN §3.6). Cancelling the calling
    /// task skips every item not started yet and throws `.cancelled`.
    private nonisolated static func copy(
        _ source: URL, to staged: URL, report: (@Sendable (Int) -> Void)?
    ) async throws {
        let gate = CopyGate(report: report)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let files = FileManager()
                    files.delegate = gate
                    let result = Result { try files.copyItem(at: source, to: staged) }
                    files.delegate = nil
                    done.resume(with: gate.isCancelled ? .failure(FileRefusal.cancelled) : result)
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    // MARK: Undo

    /// Takes back a trash or an import, newest step first: renames out of the trash or back to the drop source
    /// (`RENAME_EXCL`; a taken name becomes "name 2"), or trashes our copy or our alias (never what it points to). Takes an `.undo` intent and a record
    /// this operator issued and has not replayed yet (a refused intent leaves the record usable). Every step
    /// re-checks the item's identity first. A step the system refuses (the real Trash under privacy protection,
    /// S11) is refused with `.notPermitted`; Finder's Put Back still works then.
    public func undo(_ record: FileUndoRecord, _ intent: ExplicitIntent) async -> FileResult {
        let steps = Array(record.steps.reversed())
        if let r = refusal(for: intent, .undo) ?? rootRefusal() ?? (redeem(record) ? nil : .unknownRecord) {
            let outcomes = steps.map { FileOutcome.refused(Self.subject(of: $0), r) }
            for (step, outcome) in zip(steps, outcomes) {
                self.record(Self.logOp(step), outcome, inodes: [step.key.inode], intent: intent)
            }
            return FileResult(outcomes: outcomes, undo: nil)
        }
        var outcomes: [FileOutcome] = []
        for step in steps {
            let outcome = await undoStep(step)
            outcomes.append(outcome)
            self.record(Self.logOp(step), outcome, inodes: [step.key.inode], intent: intent)
        }
        return FileResult(outcomes: outcomes, undo: nil)
    }

    private func undoStep(_ step: FileUndoRecord.Step) async -> FileOutcome {
        switch step {
        case let .putBack(trashed, original, key):
            guard let trashed else { return .refused(original, .notInTrash) }
            guard inSandbox(trashed) else { return .refused(trashed, .outsideSandbox) }
            guard trasher.contains(trashed) else { return .refused(trashed, .notInTrash) }
            guard let back = deskChild(original) else { return .refused(trashed, .outsideRoot) }
            if let r = check(trashed, is: key) { return .refused(trashed, r) }
            return place(trashed, in: root, name: back.lastPathComponent, expecting: key)
        case let .moveBack(current, source, key):
            let back = source.standardizedFileURL
            guard inSandbox(back) else { return .refused(current, .outsideSandbox) }
            guard let item = deskChild(current) else { return .refused(current, .outsideRoot) }
            if let r = check(item, is: key) { return .refused(current, r) }
            return place(item, in: back.deletingLastPathComponent(), name: back.lastPathComponent, expecting: key)
        case let .trashCopy(url, key), let .trashAlias(url, key):
            if let r = trashRefusal() { return .refused(url, r) }
            guard let item = deskChild(url) else { return .refused(url, .outsideRoot) }
            if let r = check(item, is: key) { return .refused(url, r) }
            switch await trashChecked(item, is: key) {
            case let .success(to): return .trashed(url, to: to)
            case let .failure(r): return .refused(url, r)
            }
        }
    }

    /// Renames `item` to `folder/name` (or a free numbered name), then checks the item that moved is still `key`.
    private func place(_ item: URL, in folder: URL, name: String, expecting key: TokenKey) -> FileOutcome {
        switch FileMoves.renameToFreeName(
            item, in: folder, name: name, splitsExtension: FileMoves.splitsExtension(item), before: hooks.beforeRename
        ) {
        case let .success(placed):
            if let r = verify(placed.url, is: key, elseReturnTo: item) { return .refused(item, r) }
            return placed.renamed ? .renamed(item, to: placed.url, op: .move) : .moved(item, to: placed.url)
        case let .failure(f):
            return .refused(item, f.refusal)
        }
    }

    /// A record for what changed, kept open for one undo; nil when nothing did.
    func issue(_ kind: FileUndoRecord.Kind, _ steps: [FileUndoRecord.Step]) -> FileUndoRecord? {
        guard !steps.isEmpty else { return nil }
        let record = FileUndoRecord(kind: kind, steps: steps)
        openRecords.append(record)
        if openRecords.count > Self.maxOpenRecords { openRecords.removeFirst(openRecords.count - Self.maxOpenRecords) }
        return record
    }

    /// Closes `record` if this operator issued it and it is still open.
    private func redeem(_ record: FileUndoRecord) -> Bool {
        guard let i = openRecords.firstIndex(of: record) else { return false }
        openRecords.remove(at: i)
        return true
    }

    private static func subject(of step: FileUndoRecord.Step) -> URL {
        switch step {
        case let .putBack(trashed, original, _): trashed ?? original
        case let .moveBack(current, _, _): current
        case let .trashCopy(url, _), let .trashAlias(url, _): url
        }
    }

    private static func logOp(_ step: FileUndoRecord.Step) -> OperationLog.Entry.Op {
        switch step {
        case .putBack: .putBack
        case .moveBack: .moveBack
        case .trashCopy: .trashCopy
        case .trashAlias: .trashAlias
        }
    }

    // MARK: Eject

    /// Unmounts and ejects the volume mounted at `volume`. Takes a `.menuItem` or `.inventory` intent. Never in
    /// demo and test modes. The unmount (seconds for a slow server) runs on a GCD thread, so the actor serves other
    /// requests meanwhile and their intents do not go stale waiting.
    public func eject(_ volume: URL, _ intent: ExplicitIntent) async -> FileOutcome {
        let outcome: FileOutcome
        if let r = refusal(for: intent, .eject) {
            outcome = .refused(volume, r)
        } else if sandboxRoots != nil, hooks.unmount == nil {
            outcome = .refused(volume, .outsideSandbox)
        } else if !(hooks.ejectable ?? Self.isEjectableVolume)(volume) {
            outcome = .refused(volume, .notEjectable)
        } else {
            do {
                try await Self.unmount(volume, hooks.unmount)
                outcome = .ejected(volume)
            } catch {
                outcome = .refused(volume, FileRefusal.from(error))
            }
        }
        record(.eject, outcome, inodes: [], intent: intent)
        return outcome
    }

    /// `NSWorkspace.unmountAndEjectDevice(at:)` (or the test seam) off the actor.
    private nonisolated static func unmount(_ volume: URL, _ seam: (@Sendable (URL) throws -> Void)?) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result {
                    if let seam { try seam(volume) } else { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) }
                })
            }
        }
    }

    /// A mount point the drive hub would offer to eject (`isEjectable`). The system's own volumes under
    /// `/System/Volumes` and `/dev` never are.
    static func isEjectableVolume(_ url: URL) -> Bool {
        let path = DesktopLocator.canonicalPath(url).lowercased()
        let system = ["/", "/dev", "/system/volumes"]
        if system.contains(path) || path.hasPrefix("/dev/") || path.hasPrefix("/system/volumes/") { return false }
        let keys: Set<URLResourceKey> = [
            .isVolumeKey, .volumeIsRootFileSystemKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey,
            .volumeIsBrowsableKey, .volumeIsInternalKey,
        ]
        guard let v = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: keys), v.isVolume == true else {
            return false
        }
        return isEjectable(VolumeWatcher.Facts(
            isInternal: v.volumeIsInternal, isLocal: v.volumeIsLocal ?? true, isRemovable: v.volumeIsRemovable ?? false,
            isEjectable: v.volumeIsEjectable ?? false, isBrowsable: v.volumeIsBrowsable ?? false,
            isRoot: v.volumeIsRootFileSystem ?? true
        ))
    }

    /// `VolumeWatcher`'s rule: a browsable volume other than the startup disk that is ejectable, removable or a
    /// server.
    static func isEjectable(_ f: VolumeWatcher.Facts) -> Bool {
        !f.isRoot && f.isBrowsable && (f.isEjectable || f.isRemovable || !f.isLocal)
    }

    // MARK: Checks

    /// Spends `intent`, then says why it does not let `method` act: stale (on the monotonic clock), spent or never
    /// issued, or from an origin that does not fit.
    private func refusal(for intent: ExplicitIntent, _ method: Method) -> FileRefusal? {
        let unspent = IntentLedger.shared.spend(intent.id)
        if !intent.isFresh(at: uptime()) { return .staleIntent }
        if !unspent { return .spentIntent }
        return method.origins.contains(intent.origin) ? nil : .wrongOrigin
    }

    private func rootRefusal() -> FileRefusal? {
        inSandbox(root) ? nil : .outsideSandbox
    }

    /// In demo and test modes the trash must be our own folder inside a sandbox root.
    private func trashRefusal() -> FileRefusal? {
        if let r = rootRefusal() { return r }
        guard sandboxRoots != nil else { return nil }
        return trasher.trashFolder.map(inSandbox) == true ? nil : .outsideSandbox
    }

    /// `root/<name>` when `url` is a direct child of the desktop folder (`..` and symlinks in its parent resolved),
    /// else nil. The item itself is never resolved: a symlink on the desk is acted on as the link.
    private func deskChild(_ url: URL) -> URL? {
        guard SafetyGuard.isDirectChild(url, of: root) else { return nil }
        return root.appendingPathComponent(url.standardizedFileURL.lastPathComponent, isDirectory: false)
    }

    /// Inside a sandbox root (always true outside demo and test modes). Only the parent is resolved, because
    /// that is the path a rename acts on.
    private func inSandbox(_ url: URL) -> Bool {
        guard let roots = sandboxRoots else { return true }
        let path = Self.parentResolvedPath(url)
        return roots.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// The realpath of `url`'s parent plus its own name.
    private static func parentResolvedPath(_ url: URL) -> String {
        let u = url.standardizedFileURL
        guard u.path != "/" else { return "/" }
        return (DesktopLocator.canonicalPath(u.deletingLastPathComponent()) as NSString)
            .appendingPathComponent(u.lastPathComponent)
    }

    /// Device and inode of the item at `url` (`stat` when `follow`, else `lstat`), and whether it is a folder.
    private static func fileID(_ url: URL, follow: Bool) -> (dev: dev_t, ino: ino_t, isFolder: Bool)? {
        var st = stat()
        let ok: Bool = url.withUnsafeFileSystemRepresentation { p in
            guard let p else { return false }
            return (follow ? stat(p, &st) : lstat(p, &st)) == 0
        }
        return ok ? (st.st_dev, st.st_ino, st.st_mode & S_IFMT == S_IFDIR) : nil
    }

    /// `a` and `b` (symlinks followed) are one item.
    private static func sameItem(_ a: URL, _ b: URL) -> Bool {
        guard let x = fileID(a, follow: true), let y = fileID(b, follow: true) else { return false }
        return x.dev == y.dev && x.ino == y.ino
    }

    /// Time of check: the item at `url` right now has identity `key`.
    private func check(_ url: URL, is key: TokenKey) -> FileRefusal? {
        hooks.beforeCheck?(url)
        switch identity(of: url) {
        case let .success(found): return found == key ? nil : .identityChanged
        case let .failure(r): return r
        }
    }

    /// After acting: the item now at `placed` is `key`. When it is not (another item was swapped in between the
    /// check and the act, as an editor's safe-save does), it goes straight back to `original`, under a free
    /// numbered name if that is taken now, and the act is refused. An item that cannot be stat'ed there (the
    /// Trash under privacy protection) is taken as it is.
    private func verify(_ placed: URL, is key: TokenKey, elseReturnTo original: URL) -> FileRefusal? {
        guard case let .success(found) = identity(of: placed), found != key else { return nil }
        _ = FileMoves.renameToFreeName(
            placed, in: original.deletingLastPathComponent(), name: original.lastPathComponent,
            splitsExtension: FileMoves.splitsExtension(placed)
        )
        return .identityChanged
    }

    /// The volume and inode of the item at `url` itself (`lstat`; a symlink is not followed). An item whose
    /// volume cannot be read takes the desktop folder's, as the scanner does.
    func identity(of url: URL) -> Result<TokenKey, FileRefusal> {
        var st = stat()
        let e: Int32 = url.withUnsafeFileSystemRepresentation { p in
            guard let p else { return EINVAL }
            return lstat(p, &st) == 0 ? 0 : errno
        }
        guard e == 0 else { return .failure(FileRefusal.from(errno: e)) }
        let volume = volumeID(url) ?? volumeID(root) ?? "unknown"
        return .success(TokenKey(volume: volume, inode: UInt64(st.st_ino)))
    }

    // MARK: Log

    private func refuseAll(
        _ urls: [URL], _ r: FileRefusal, op: OperationLog.Entry.Op, intent: ExplicitIntent, inodes: [[UInt64]]? = nil
    ) -> FileResult {
        let outcomes = urls.map { FileOutcome.refused($0, r) }
        for (i, o) in outcomes.enumerated() { record(op, o, inodes: inodes?[i] ?? [], intent: intent) }
        return FileResult(outcomes: outcomes, undo: nil)
    }

    /// A failed log write never undoes or blocks the operation; the unified log still has the line.
    private func record(_ op: OperationLog.Entry.Op, _ outcome: FileOutcome, inodes: [UInt64], intent: ExplicitIntent) {
        var names = [outcome.source.lastPathComponent]
        if let to = outcome.destination?.lastPathComponent, to != names[0] { names.append(to) }
        let entry = OperationLog.Entry(
            time: clock(), op: op, origin: intent.origin, names: names, inodes: inodes, outcome: outcome.logOutcome
        )
        try? log.append(entry)
    }
}

/// Gates the items of one copy and counts them: after `cancel()` every item not started yet is skipped.
private final class CopyGate: NSObject, FileManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = 0
    private let report: (@Sendable (Int) -> Void)?

    init(report: (@Sendable (Int) -> Void)?) {
        self.report = report
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }

    func fileManager(_ fileManager: FileManager, shouldCopyItemAt srcURL: URL, to dstURL: URL) -> Bool {
        let n: Int? = lock.withLock {
            guard !cancelled else { return nil }
            started += 1
            return started
        }
        guard let n else { return false }
        report?(n)
        return !isCancelled
    }
}

// MARK: Rename primitive

/// The one rename every user-file move goes through (FileOperator and FakeTrasher): `renamex_np` with
/// `RENAME_EXCL`, so an existing item is never replaced, even one that appears after a name was chosen.
enum FileMoves {
    /// Names tried: the name itself, then up to "name 100".
    static let maxAttempts = 100
    /// The hidden staging folder a copy uses when the system has no item-replacement folder on the desk's volume.
    static let partialPrefix = ".deskterior-partial-"

    enum Failure: Error, Equatable {
        case noFreeName
        case errno(Int32)

        var refusal: FileRefusal {
            switch self {
            case .noFreeName: .noFreeName
            case let .errno(e): FileRefusal.from(errno: e)
            }
        }
    }

    struct Placed: Equatable {
        var url: URL
        /// Placed under a numbered name because the name asked for was taken.
        var renamed: Bool
    }

    /// `renamex_np(from, to, RENAME_EXCL)`: 0, or the errno.
    static func renameExclusive(_ from: URL, _ to: URL) -> Int32 {
        from.withUnsafeFileSystemRepresentation { f in
            to.withUnsafeFileSystemRepresentation { t in
                guard let f, let t else { return EINVAL }
                return renamex_np(f, t, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
    }

    /// Renames `item` to `folder/name`, or to the first free numbered name. `before` runs right before each
    /// attempt with its destination. Only `EEXIST` moves on to the next name; any other error stops.
    static func renameToFreeName(
        _ item: URL, in folder: URL, name: String, splitsExtension: Bool, before: ((URL) -> Void)? = nil
    ) -> Result<Placed, Failure> {
        for (i, candidate) in candidates(for: name, splitsExtension: splitsExtension).enumerated() {
            let destination = folder.appendingPathComponent(candidate, isDirectory: false)
            before?(destination)
            let e = renameExclusive(item, destination)
            if e == 0 { return .success(Placed(url: destination, renamed: i > 0)) }
            if e != EEXIST { return .failure(.errno(e)) }
        }
        return .failure(.noFreeName)
    }

    /// Finder-style names: `name`, then "report 2.pdf", "report 3.pdf" … ("Notes 2.rtfd", "Folder 2"). A name
    /// that already ends in " <n>" counts on from n ("report 2.pdf" → "report 3.pdf"). Only the last extension is
    /// kept apart, and only for files and packages. Numbered names are shortened to fit 255 UTF-8 bytes.
    static func candidates(for name: String, splitsExtension: Bool) -> [String] {
        var stem = name
        var ext = ""
        if splitsExtension, let dot = name.lastIndex(of: "."), dot > name.startIndex {
            let e = name[dot...]
            if e.count > 1, !e.contains(" ") {
                stem = String(name[..<dot])
                ext = String(e)
            }
        }
        var first = 2
        if let space = stem.lastIndex(of: " "), space > stem.startIndex {
            let digits = stem[stem.index(after: space)...]
            if !digits.isEmpty, digits.first != "0", digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
               let n = Int(digits), n >= 2
            {
                stem = String(stem[..<space])
                first = n + 1
            }
        }
        return [name] + (0..<(maxAttempts - 1)).map { i in
            let suffix = " \(first + i)" + ext
            var base = stem
            while !base.isEmpty, base.utf8.count + suffix.utf8.count > 255 { base.removeLast() }
            return base + suffix
        }
    }

    /// Files and packages keep their extension apart when numbered; plain folders do not.
    static func splitsExtension(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return true }
        return (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }
}
