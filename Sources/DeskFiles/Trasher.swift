import AppKit
import Foundation

/// Moves items to a trash (DESIGN §3.5). Internal: only `FileOperator` calls it, after its own checks (intent,
/// confinement, identity); nothing is ever deleted. Callers pick one with `FileOperator.Trash`.
protocol Trasher: Sendable {
    /// The one folder every item goes to, when there is one (`FakeTrasher`); nil for the system Trash, which is
    /// per volume. In demo and test modes `FileOperator` requires it inside a sandbox root.
    var trashFolder: URL? { get }
    /// Moves the item at `url` (the item itself; a symlink is not followed) to the trash. Returns its URL there,
    /// or nil when the trash does not say.
    func trash(_ url: URL) async throws -> URL?
    /// True when `url` is directly inside this trash: the only places undo renames items out of.
    func contains(_ url: URL) -> Bool
}

/// The real Trash, through `NSWorkspace.recycle` (the Finder way, so Finder's Put Back works too).
struct SystemTrasher: Trasher {
    var trashFolder: URL? { nil }

    func trash(_ url: URL) async throws -> URL? {
        let moved = try await NSWorkspace.shared.recycle([url])
        return moved[url] ?? (moved.count == 1 ? moved.first?.value : nil)
    }

    /// Path arithmetic only: the Trash is never listed or inspected.
    func contains(_ url: URL) -> Bool {
        Self.isTrashChild(url, homeTrash: FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first,
                          uid: getuid())
    }

    /// A direct child of `~/.Trash` or of a volume's `.Trashes/<uid>`, by spelling.
    static func isTrashChild(_ url: URL, homeTrash: URL?, uid: uid_t) -> Bool {
        let u = url.standardizedFileURL
        let name = u.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return false }
        let parent = u.deletingLastPathComponent()
        if let homeTrash, parent.path == homeTrash.standardizedFileURL.path { return true }
        return parent.lastPathComponent == String(uid) && parent.deletingLastPathComponent().lastPathComponent == ".Trashes"
    }
}

/// A trash folder of our own for demo, headless and test modes (DESIGN §3.7 item 7). Items are renamed into it
/// with `RENAME_EXCL` under a free Finder-style name ("name 2"), so nothing in it is ever replaced. The folder
/// must stay outside the desktop folder and the mirrored folder; that is checked when it is made and before
/// every move.
struct FakeTrasher: Trasher {
    let folder: URL
    private let desktop: URL
    private let mirrored: URL?

    /// Refuses a folder inside the desktop folder or the mirrored folder; creates it otherwise.
    init(folder: URL, desktop: URL = DesktopLocator.defaultDesktopURL(), mirrored: URL? = nil) throws {
        let dir = URL(fileURLWithPath: DesktopLocator.canonicalPath(folder), isDirectory: true)
        try SafetyGuard.checkOwnFolder(dir, desktop: desktop, mirrored: mirrored)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.folder = dir
        self.desktop = desktop
        self.mirrored = mirrored
    }

    var trashFolder: URL? { folder }

    func trash(_ url: URL) async throws -> URL? {
        try SafetyGuard.checkOwnFolder(folder, desktop: desktop, mirrored: mirrored)
        let item = url.standardizedFileURL
        switch FileMoves.renameToFreeName(
            item, in: folder, name: item.lastPathComponent, splitsExtension: FileMoves.splitsExtension(item)
        ) {
        case let .success(placed): return placed.url
        case let .failure(f): throw f.refusal
        }
    }

    func contains(_ url: URL) -> Bool {
        SafetyGuard.isDirectChild(url, of: folder)
    }
}
