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
    /// case-insensitive), so the check errs toward "inside".
    public static func isInsideDesktop(_ url: URL, desktop: URL = defaultDesktopURL()) -> Bool {
        let root = canonicalPath(desktop).lowercased()
        let path = canonicalPath(url).lowercased()
        if path == root { return true }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// True when `url` is a strict ancestor of `desktop` (for example the home folder): mirroring it would
    /// put the desktop folder itself on the desk.
    public static func enclosesDesktop(_ url: URL, desktop: URL = defaultDesktopURL()) -> Bool {
        isInsideDesktop(desktop, desktop: url) && !isInsideDesktop(url, desktop: desktop)
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
