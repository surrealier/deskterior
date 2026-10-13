import Foundation

/// Locates the user's desktop folder. This is the only file allowed to name it (file-safety lint, DESIGN §3.7);
/// everything else asks `DesktopLocator`.
public enum DesktopLocator {
    /// Environment overrides for the mirrored folder, in priority order (`--desktop-folder` wins over both).
    public static let environmentKeys = ["DESKTERIOR_DESKTOP_FOLDER", "DESKTERIOR_DESKTOP"]

    /// The current user's desktop folder as `FileManager` reports it.
    public static func defaultDesktopURL() -> URL {
        if let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// The folder to mirror and whether it came from an override.
    public struct Resolution: Sendable, Equatable {
        public let url: URL
        public let isOverride: Bool
    }

    /// `override` (a `--desktop-folder` value; `~` expands), else the first non-empty environment override,
    /// else the real desktop folder. The result is standardized but not resolved.
    public static func resolve(override: String?, environment: [String: String] = [:]) -> Resolution {
        let candidate = override.flatMap { $0.isEmpty ? nil : $0 }
            ?? environmentKeys.lazy.compactMap { environment[$0].flatMap { $0.isEmpty ? nil : $0 } }.first
        guard let candidate else { return Resolution(url: defaultDesktopURL(), isOverride: false) }
        let path = (candidate as NSString).expandingTildeInPath
        return Resolution(url: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL, isOverride: true)
    }

    /// True when `url` is `desktop` or anything below it, after resolving `.`/`..` and symlinks. Paths that do
    /// not exist yet resolve through their deepest existing ancestor. Case is ignored (default APFS volumes are
    /// case-insensitive), so the check errs toward "inside". A path that is inside by spelling alone is answered
    /// without touching the file system, so checking it never looks inside a protected folder.
    public static func isInsideDesktop(_ url: URL, desktop: URL = defaultDesktopURL()) -> Bool {
        let root = canonicalPath(desktop).lowercased()
        let lexical = url.standardizedFileURL.path.lowercased()
        let lexicalRoot = desktop.standardizedFileURL.path.lowercased()
        if isSameOrBelow(lexical, lexicalRoot) || isSameOrBelow(lexical, root) { return true }
        return isSameOrBelow(canonicalPath(url).lowercased(), root)
    }

    private static func isSameOrBelow(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// How a path relates to the desktop folder.
    public enum Relation: Sendable, Equatable {
        case same, inside, encloses, unrelated
    }

    /// `url` compared with `desktop` (case-insensitive, `..` and symlinks resolved). Spelling is checked
    /// first, so a path that is plainly the desktop or inside it is classified without any file-system lookup.
    public static func relation(of url: URL, to desktop: URL = defaultDesktopURL()) -> Relation {
        let rootC = canonicalPath(desktop).lowercased()
        let rootL = desktop.standardizedFileURL.path.lowercased()
        let lexical = url.standardizedFileURL.path.lowercased()
        for root in [rootL, rootC] {
            if lexical == root { return .same }
            if isSameOrBelow(lexical, root) { return .inside }
        }
        let canonical = canonicalPath(url).lowercased()
        if canonical == rootC { return .same }
        if isSameOrBelow(canonical, rootC) { return .inside }
        if isSameOrBelow(rootC, canonical) || isSameOrBelow(rootL, lexical) { return .encloses }
        return .unrelated
    }

    /// True when `url` is a strict ancestor of `desktop` (for example the home folder): mirroring it would
    /// put the desktop folder itself on the desk.
    public static func enclosesDesktop(_ url: URL, desktop: URL = defaultDesktopURL()) -> Bool {
        relation(of: url, to: desktop) == .encloses
    }

    /// `realpath(3)` of `url`, or of its deepest existing ancestor with the remaining components appended.
    public static func canonicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL.path
        var head = standardized
        var tail: [String] = []
        while true {
            if let resolved = realpath(head, nil) {
                defer { free(resolved) }
                var out = String(cString: resolved)
                for component in tail.reversed() { out = (out as NSString).appendingPathComponent(component) }
                return out
            }
            let parent = (head as NSString).deletingLastPathComponent
            if parent == head || parent.isEmpty { return standardized }
            tail.append((head as NSString).lastPathComponent)
            head = parent
        }
    }
}
