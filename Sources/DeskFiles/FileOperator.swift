import AppKit
import DeskCore
import Foundation

// MARK: Results

/// Why a file action did not happen. Nothing was changed for that item.
public enum FileRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    /// The intent is older than `ExplicitIntent.maxAge`, or from the future.
    case staleIntent
    /// Demo and test modes: a path, the desktop folder or the trash lies outside every sandbox root.
    case outsideSandbox
    /// Not a direct child of the desktop folder.
    case outsideRoot
    /// Undo: the item is not directly inside our trash, or the trash never said where it went.
    case notInTrash
    /// Nothing is there now.
    case missing
    /// Time of check: the item there now is not the one the token stands for (volume or inode differ).
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
    /// Any other failure: an errno, or a Cocoa error code.
    case failed(Int)

    public var description: String {
        switch self {
        case .staleIntent: "stale-intent"
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
    /// Moved or copied to `to` under a free Finder-style name ("name 2") because the name asked for was taken.
    case renamed(URL, to: URL, op: ImportOp)
    /// Already a direct child of the desktop folder: placement only, no file change.
    case unchanged(URL)
    case ejected(URL)
    case refused(URL, FileRefusal)

    /// The URL the request named.
    public var source: URL {
        switch self {
        case let .trashed(u, _), let .moved(u, _), let .copied(u, _), let .renamed(u, _, _), let .unchanged(u),
             let .ejected(u), let .refused(u, _):
            u
        }
    }

    /// Where the item is now, when it moved.
    public var destination: URL? {
        switch self {
        case let .trashed(_, to): to
        case let .moved(_, to), let .copied(_, to), let .renamed(_, to, _): to
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
        case .trashed, .moved, .copied, .ejected: "ok"
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

/// The only code that changes user files (DESIGN §3.5–§3.7). Every mutating method takes a fresh
/// `ExplicitIntent` and, item by item:
/// - confines targets to direct children of the realpath'd desktop folder (drop sources and trash URLs are the
///   only exceptions), and in demo and test modes every path to `sandboxRoots`;
/// - re-stats the item right before acting and refuses when its volume or inode is not the expected one;
/// - renames with `renamex_np(RENAME_EXCL)`, so nothing is ever replaced: a taken name becomes "name 2" … "name 100";
/// - trashes, never deletes. The only removal is our own `.deskterior-partial-*` copy after a failed copy;
/// - logs the outcome to `OperationLog`.
public actor FileOperator {
    /// The realpath'd desktop folder.
    public nonisolated let root: URL
    private let trasher: any Trasher
    private let log: OperationLog
    private let sandboxRoots: [String]?
    private let clock: @Sendable () -> Date
    private let volumeID: @Sendable (URL) -> String?
    private var hooks = Hooks()

    /// Test seams for races.
    struct Hooks: Sendable {
        /// Runs right before every final rename, with the destination it is about to try.
        var beforeRename: (@Sendable (URL) -> Void)?
        /// Runs right before the time-of-check re-stat of an item.
        var beforeCheck: (@Sendable (URL) -> Void)?
    }

    /// `sandboxRoots` is non-nil in demo, headless and test modes: then every path touched (the desktop folder,
    /// drop sources, undo destinations, the trash folder) must lie inside one of them, the system Trash is never
    /// used and nothing is ejected. `volumeID` names an item's volume (`TokenKey.volume`; same volume = move).
    public init(
        root: URL, trasher: any Trasher, log: OperationLog, sandboxRoots: [URL]?,
        clock: @escaping @Sendable () -> Date = { Date() },
        volumeID: @escaping @Sendable (URL) -> String? = FileOperator.volumeUUID
    ) {
        self.root = URL(fileURLWithPath: DesktopLocator.canonicalPath(root), isDirectory: true)
        self.trasher = trasher
        self.log = log
        self.sandboxRoots = sandboxRoots?.map { DesktopLocator.canonicalPath($0) }
        self.clock = clock
        self.volumeID = volumeID
    }

    func setHooks(_ h: Hooks) { hooks = h }

    /// `URLResourceValues.volumeUUIDString`, read fresh (never from a URL's cache).
    public static func volumeUUID(_ url: URL) -> String? {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    // MARK: Trash

    /// Moves each `urls[i]` to the trash if it is still `expecting[i]`.
    public func trash(_ urls: [URL], expecting: [TokenKey], _ intent: ExplicitIntent) async -> FileResult {
        if let r = refusal(for: intent) ?? (urls.count == expecting.count ? nil : .mismatchedRequest) {
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
        return FileResult(outcomes: outcomes, undo: steps.isEmpty ? nil : FileUndoRecord(kind: .trash, steps: steps))
    }

    private func trashOne(_ url: URL, expecting key: TokenKey) async -> (FileOutcome, FileUndoRecord.Step?) {
        if let r = trashRefusal() { return (.refused(url, r), nil) }
        guard let item = deskChild(url) else { return (.refused(url, .outsideRoot), nil) }
        if let r = check(item, is: key) { return (.refused(url, r), nil) }
        do {
            let trashed = try await trasher.trash(item)
            return (.trashed(url, to: trashed), .putBack(trashed: trashed, original: item, key: key))
        } catch {
            return (.refused(url, FileRefusal.from(error)), nil)
        }
    }

    // MARK: Import

    /// Brings dropped items into the desktop folder. Same volume and `.move`: renamed in. Otherwise (another
    /// volume, `.copy`, or a move the system refuses): copied to a hidden partial name in the desktop folder, then
    /// renamed into place. A source is never deleted. Folders and packages go as one unit.
    public func importItems(_ urls: [URL], op: ImportOp, _ intent: ExplicitIntent) async -> FileResult {
        if let r = refusal(for: intent) ?? rootRefusal() {
            return refuseAll(urls, r, op: op == .move ? .importMove : .importCopy, intent: intent)
        }
        var outcomes: [FileOutcome] = []
        var steps: [FileUndoRecord.Step] = []
        for url in urls {
            let (outcome, step, inodes) = importOne(url, op: op)
            outcomes.append(outcome)
            if let step { steps.append(step) }
            let copied: Bool = switch outcome {
            case .copied, .renamed(_, _, .copy): true
            case .refused, .unchanged: op == .copy
            default: false
            }
            record(copied ? .importCopy : .importMove, outcome, inodes: inodes, intent: intent)
        }
        return FileResult(outcomes: outcomes, undo: steps.isEmpty ? nil : FileUndoRecord(kind: .importItems, steps: steps))
    }

    private func importOne(_ url: URL, op: ImportOp) -> (FileOutcome, FileUndoRecord.Step?, [UInt64]) {
        let source = url.standardizedFileURL
        guard inSandbox(source) else { return (.refused(url, .outsideSandbox), nil, []) }
        if SafetyGuard.isDirectChild(source, of: root) { return (.unchanged(url), nil, []) }
        let sourcePath = Self.parentResolvedPath(source)
        if root.path == sourcePath || root.path.hasPrefix(sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/") {
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
        let sourceVolume = volumeID(source)
        if op == .move, let sourceVolume, sourceVolume == volumeID(root) {
            switch FileMoves.renameToFreeName(source, in: root, name: name, splitsExtension: splits, before: hooks.beforeRename) {
            case let .success(placed):
                let outcome: FileOutcome = placed.renamed ? .renamed(url, to: placed.url, op: .move) : .moved(url, to: placed.url)
                let back = URL(fileURLWithPath: sourcePath, isDirectory: false)
                return (outcome, .moveBack(current: placed.url, source: back, key: key), [key.inode])
            case let .failure(.errno(e)) where e == EXDEV || e == EPERM || e == EACCES:
                break // Another volume after all, or a protected folder (S12): copy instead.
            case let .failure(f):
                return (.refused(url, f.refusal), nil, [key.inode])
            }
        }
        return copyIn(url, from: source, name: name, splitsExtension: splits, sourceInode: key.inode)
    }

    /// Copies to `.deskterior-partial-<uuid>` in the desktop folder (hidden, so the scanner skips it), then
    /// renames it into place. Any failure removes the partial copy.
    private func copyIn(
        _ url: URL, from source: URL, name: String, splitsExtension: Bool, sourceInode: UInt64
    ) -> (FileOutcome, FileUndoRecord.Step?, [UInt64]) {
        let partial = root.appendingPathComponent(FileMoves.partialPrefix + UUID().uuidString, isDirectory: false)
        do {
            try FileManager.default.copyItem(at: source, to: partial)
        } catch {
            removePartial(partial)
            return (.refused(url, FileRefusal.from(error)), nil, [sourceInode])
        }
        let key: TokenKey
        switch identity(of: partial) {
        case let .success(k): key = k
        case let .failure(r):
            removePartial(partial)
            return (.refused(url, r), nil, [sourceInode])
        }
        switch FileMoves.renameToFreeName(partial, in: root, name: name, splitsExtension: splitsExtension, before: hooks.beforeRename) {
        case let .success(placed):
            let outcome: FileOutcome = placed.renamed ? .renamed(url, to: placed.url, op: .copy) : .copied(url, to: placed.url)
            return (outcome, .trashCopy(placed.url, key: key), [sourceInode, key.inode])
        case let .failure(f):
            removePartial(partial)
            return (.refused(url, f.refusal), nil, [sourceInode])
        }
    }

    /// Removes our own partial copy; nothing else is ever removed.
    private func removePartial(_ url: URL) {
        guard url.lastPathComponent.hasPrefix(FileMoves.partialPrefix), SafetyGuard.isDirectChild(url, of: root) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Undo

    /// Takes back a trash or an import, newest step first: renames out of the trash or back to the drop source
    /// (`RENAME_EXCL`; a taken name becomes "name 2"), or trashes our copy. Every step re-checks the item's
    /// identity first. A step the system refuses (the real Trash under privacy protection, S11) is refused with
    /// `.notPermitted`; Finder's Put Back still works then.
    public func undo(_ record: FileUndoRecord, _ intent: ExplicitIntent) async -> FileResult {
        let steps = Array(record.steps.reversed())
        if let r = refusal(for: intent) ?? rootRefusal() {
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
            return place(trashed, in: root, name: back.lastPathComponent)
        case let .moveBack(current, source, key):
            let back = source.standardizedFileURL
            guard inSandbox(back) else { return .refused(current, .outsideSandbox) }
            guard let item = deskChild(current) else { return .refused(current, .outsideRoot) }
            if let r = check(item, is: key) { return .refused(current, r) }
            return place(item, in: back.deletingLastPathComponent(), name: back.lastPathComponent)
        case let .trashCopy(url, key):
            if let r = trashRefusal() { return .refused(url, r) }
            guard let item = deskChild(url) else { return .refused(url, .outsideRoot) }
            if let r = check(item, is: key) { return .refused(url, r) }
            do {
                return .trashed(url, to: try await trasher.trash(item))
            } catch {
                return .refused(url, FileRefusal.from(error))
            }
        }
    }

    private func place(_ item: URL, in folder: URL, name: String) -> FileOutcome {
        switch FileMoves.renameToFreeName(
            item, in: folder, name: name, splitsExtension: FileMoves.splitsExtension(item), before: hooks.beforeRename
        ) {
        case let .success(placed): placed.renamed ? .renamed(item, to: placed.url, op: .move) : .moved(item, to: placed.url)
        case let .failure(f): .refused(item, f.refusal)
        }
    }

    private static func subject(of step: FileUndoRecord.Step) -> URL {
        switch step {
        case let .putBack(trashed, original, _): trashed ?? original
        case let .moveBack(current, _, _): current
        case let .trashCopy(url, _): url
        }
    }

    private static func logOp(_ step: FileUndoRecord.Step) -> OperationLog.Entry.Op {
        switch step {
        case .putBack: .putBack
        case .moveBack: .moveBack
        case .trashCopy: .trashCopy
        }
    }

    // MARK: Eject

    /// Unmounts and ejects the volume mounted at `volume`. Never in demo and test modes.
    public func eject(_ volume: URL, _ intent: ExplicitIntent) async -> FileOutcome {
        let outcome: FileOutcome
        if let r = refusal(for: intent) {
            outcome = .refused(volume, r)
        } else if sandboxRoots != nil {
            outcome = .refused(volume, .outsideSandbox)
        } else if !Self.isEjectableVolume(volume) {
            outcome = .refused(volume, .notEjectable)
        } else {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                outcome = .ejected(volume)
            } catch {
                outcome = .refused(volume, FileRefusal.from(error))
            }
        }
        record(.eject, outcome, inodes: [], intent: intent)
        return outcome
    }

    /// A mount point that is not the startup volume.
    static func isEjectableVolume(_ url: URL) -> Bool {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isVolumeKey, .volumeIsRootFileSystemKey])
        return values?.isVolume == true && values?.volumeIsRootFileSystem != true
    }

    // MARK: Checks

    private func refusal(for intent: ExplicitIntent) -> FileRefusal? {
        intent.isFresh(at: clock()) ? nil : .staleIntent
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

    /// Time of check: the item at `url` right now has identity `key`.
    private func check(_ url: URL, is key: TokenKey) -> FileRefusal? {
        hooks.beforeCheck?(url)
        switch identity(of: url) {
        case let .success(found): return found == key ? nil : .identityChanged
        case let .failure(r): return r
        }
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

// MARK: Rename primitive

/// The one rename every user-file move goes through (FileOperator and FakeTrasher): `renamex_np` with
/// `RENAME_EXCL`, so an existing item is never replaced, even one that appears after a name was chosen.
enum FileMoves {
    /// Names tried: the name itself, then up to "name 100".
    static let maxAttempts = 100
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
