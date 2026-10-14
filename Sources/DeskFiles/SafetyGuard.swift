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
            case enclosesHome, volumeRoot, insideMirroredFolder, outsideOwnRoot
            /// A demo's drop source that is not a scratch folder of its own inside a temporary folder.
            case notScratch
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
            case .enclosesHome: "refusing the home folder or a folder that contains it: \(path)"
            case .volumeRoot: "refusing a whole volume or the volumes folder: \(path)"
            case .insideMirroredFolder: "refusing to keep our own files inside the mirrored folder: \(path)"
            case .outsideOwnRoot: "refusing to write outside our own folder: \(path)"
            case .notScratch: "refusing a drop source that is not a scratch folder inside the temporary folders: \(path)"
            }
        }
    }

    /// The folder to mirror in `mode`; it must exist and be a directory. No mode accepts a folder that contains
    /// the real desktop or the home folder, a volume root or the volumes folder: its children (Documents,
    /// Library, whole disks) would become tokens. Every mode but desk also requires an override that is neither
    /// the real desktop nor inside it.
    public static func mirrorFolder(
        _ resolution: DesktopLocator.Resolution, mode: Mode, realDesktop: URL = DesktopLocator.defaultDesktopURL(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws(Refusal) -> URL {
        let url = resolution.url
        if mode.requiresSandboxFolder, !resolution.isOverride { throw Refusal(reason: .noFolderGiven, path: url.path) }
        let relation = DesktopLocator.relation(of: url, to: realDesktop)
        switch relation {
        case .same, .inside:
            // The desktop itself or a folder in it (desk mode): neither can hold the home folder or a volume.
            if mode.requiresSandboxFolder {
                throw Refusal(reason: relation == .same ? .realDesktop : .insideRealDesktop, path: url.path)
            }
        case .encloses:
            throw Refusal(reason: .enclosesRealDesktop, path: url.path)
        case .unrelated:
            let toHome = DesktopLocator.relation(of: url, to: home)
            if toHome == .same || toHome == .encloses { throw Refusal(reason: .enclosesHome, path: url.path) }
            if isVolumeRoot(url) { throw Refusal(reason: .volumeRoot, path: url.path) }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw Refusal(reason: .missingFolder, path: url.path)
        }
        guard isDir.boolValue else { throw Refusal(reason: .notADirectory, path: url.path) }
        return url
    }

    /// A demo's drop source (`DESKTERIOR_DEMO_SOURCE`, M11): demos move files in from it, so it must be a scratch
    /// folder of its own. It must pass `mirrorFolder` in demo mode (it exists; not the real desktop, home or a
    /// volume, nor around them), lie strictly inside one of `temporaryRoots` (a root that is, holds or lies inside
    /// the home folder does not count), and not overlap the `guarded` folders (the mirrored and state folders).
    /// Returns its realpath.
    public static func scratchSource(
        _ path: String, guarded: [URL], temporaryRoots: [URL] = SafetyGuard.temporaryRoots(),
        realDesktop: URL = DesktopLocator.defaultDesktopURL(), home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws(Refusal) -> URL {
        let url = try mirrorFolder(
            DesktopLocator.resolve(override: path), mode: .demo, realDesktop: realDesktop, home: home
        )
        let roots = temporaryRoots.filter { DesktopLocator.relation(of: $0, to: home) == .unrelated }
        guard roots.contains(where: { DesktopLocator.relation(of: url, to: $0) == .inside }),
              guarded.allSatisfy({ DesktopLocator.relation(of: url, to: $0) == .unrelated })
        else { throw Refusal(reason: .notScratch, path: url.path) }
        return URL(fileURLWithPath: DesktopLocator.canonicalPath(url), isDirectory: true)
    }

    /// The temporary folders: this process's `TMPDIR`, `/private/tmp` and `/private/var/folders`.
    public static func temporaryRoots() -> [URL] {
        [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/private/tmp", isDirectory: true),
         URL(fileURLWithPath: "/private/var/folders", isDirectory: true)]
    }

    /// A mount point (`/`, `/Volumes/X`) or a folder of mount points.
    static func isVolumeRoot(_ url: URL) -> Bool {
        let path = DesktopLocator.canonicalPath(url)
        if ["/volumes", "/system/volumes"].contains(path.lowercased()) { return true }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
    }

    /// For our own folders (state, cache, artifacts): `dir` is outside the real desktop and the mirrored folder.
    public static func checkOwnFolder(_ dir: URL, desktop: URL, mirrored: URL?) throws(Refusal) {
        if DesktopLocator.isInsideDesktop(dir, desktop: desktop) {
            throw Refusal(reason: .insideRealDesktop, path: dir.path)
        }
        if let mirrored, DesktopLocator.isInsideDesktop(dir, desktop: mirrored) {
            throw Refusal(reason: .insideMirroredFolder, path: dir.path)
        }
    }

    /// For our own writes (state, cache): `url` must resolve inside `root` and outside the desktop folder and the
    /// mirrored folder.
    public static func checkOwnWrite(_ url: URL, root: URL, desktop: URL, mirrored: URL? = nil) throws(Refusal) {
        guard DesktopLocator.isInsideDesktop(url, desktop: root) else {
            throw Refusal(reason: .outsideOwnRoot, path: url.path)
        }
        try checkOwnFolder(url, desktop: desktop, mirrored: mirrored)
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
