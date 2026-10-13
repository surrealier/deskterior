import Foundation

/// Path checks that keep development modes away from the real desktop and keep our own writes inside our own
/// folders (DESIGN §3.7 items 4 and 7).
public enum SafetyGuard {
    /// The exit code for a guard refusal (`--demo`, `--headless`, `--windowed` pointed at the real desktop).
    public static let refusalExitCode: Int32 = 64

    public enum Mode: String, Sendable {
        /// The real desk: mirroring the real desktop is the point.
        case desk
        case windowed, headless, demo, test
        /// Developer tools (`deskterior-assets`).
        case tool

        /// Modes that must never see the real desktop.
        public var requiresSandboxFolder: Bool { self != .desk }
    }

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public enum Reason: String, Sendable {
            case noFolderGiven, missingFolder, notADirectory, realDesktop, insideRealDesktop, enclosesRealDesktop
            case outsideOwnRoot
        }

        public let reason: Reason
        public let path: String
        public var exitCode: Int32 { SafetyGuard.refusalExitCode }

        public var description: String {
            switch reason {
            case .noFolderGiven: "this mode needs --desktop-folder pointing at a scratch folder"
            case .missingFolder: "desktop folder does not exist: \(path)"
            case .notADirectory: "desktop folder is not a directory: \(path)"
            case .realDesktop: "refusing to use the real desktop folder in this mode: \(path)"
            case .insideRealDesktop: "refusing a folder inside the real desktop in this mode: \(path)"
            case .enclosesRealDesktop: "refusing a folder that contains the real desktop: \(path)"
            case .outsideOwnRoot: "refusing to write outside our own folder: \(path)"
            }
        }
    }

    /// The folder to mirror in `mode`. Desk mode takes the resolution as is (it must exist). Every other mode
    /// requires an override that exists, is a directory, and is neither the real desktop, inside it, nor an
    /// ancestor of it.
    public static func mirrorFolder(
        _ resolution: DesktopLocator.Resolution, mode: Mode, realDesktop: URL = DesktopLocator.defaultDesktopURL()
    ) throws(Refusal) -> URL {
        let url = resolution.url
        if mode.requiresSandboxFolder {
            guard resolution.isOverride else { throw Refusal(reason: .noFolderGiven, path: url.path) }
            let canonical = DesktopLocator.canonicalPath(url).lowercased()
            if canonical == DesktopLocator.canonicalPath(realDesktop).lowercased() {
                throw Refusal(reason: .realDesktop, path: url.path)
            }
            if DesktopLocator.isInsideDesktop(url, desktop: realDesktop) {
                throw Refusal(reason: .insideRealDesktop, path: url.path)
            }
            if DesktopLocator.enclosesDesktop(url, desktop: realDesktop) {
                throw Refusal(reason: .enclosesRealDesktop, path: url.path)
            }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw Refusal(reason: .missingFolder, path: url.path)
        }
        guard isDir.boolValue else { throw Refusal(reason: .notADirectory, path: url.path) }
        return url
    }

    /// For our own writes (state, cache): `url` must resolve inside `root` and outside the desktop folder.
    public static func checkOwnWrite(_ url: URL, root: URL, desktop: URL) throws(Refusal) {
        guard DesktopLocator.isInsideDesktop(url, desktop: root) else {
            throw Refusal(reason: .outsideOwnRoot, path: url.path)
        }
        if DesktopLocator.isInsideDesktop(url, desktop: desktop) {
            throw Refusal(reason: .insideRealDesktop, path: url.path)
        }
    }

    /// Root confinement (§3.7 item 4): `url` is a direct child of the realpath'd `root`.
    public static func isDirectChild(_ url: URL, of root: URL) -> Bool {
        let u = url.standardizedFileURL
        let name = u.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return false }
        let parent = DesktopLocator.canonicalPath(u.deletingLastPathComponent()).lowercased()
        return parent == DesktopLocator.canonicalPath(root).lowercased()
    }
}
