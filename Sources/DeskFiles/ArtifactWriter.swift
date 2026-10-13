import Foundation

/// Writes developer artifacts (snapshots, frame dumps) into one directory that is never inside the desktop
/// folder. The directory is checked when the writer is made and again before every write.
public struct ArtifactWriter: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The directory resolves inside the desktop folder.
        case insideDesktop(String)
        /// The name is not a plain file name.
        case invalidName(String)

        public var description: String {
            switch self {
            case .insideDesktop(let path): "refusing to write artifacts inside the desktop folder: \(path)"
            case .invalidName(let name): "not a plain file name: '\(name)'"
            }
        }
    }

    /// The (standardized) output directory.
    public let directory: URL
    private let desktop: URL
    private let mirrored: URL?

    /// Throws `.insideDesktop` when `directory` resolves inside `desktop` or inside the `mirrored` folder (a
    /// `--desktop-folder` override); otherwise creates it (with parents).
    public init(directory: URL, desktop: URL = DesktopLocator.defaultDesktopURL(), mirrored: URL? = nil) throws {
        let dir = directory.standardizedFileURL
        guard !Self.isInside(dir, desktop, mirrored) else { throw Failure.insideDesktop(dir.path) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        self.desktop = desktop
        self.mirrored = mirrored
    }

    private static func isInside(_ dir: URL, _ desktop: URL, _ mirrored: URL?) -> Bool {
        DesktopLocator.isInsideDesktop(dir, desktop: desktop)
            || mirrored.map { DesktopLocator.isInsideDesktop(dir, desktop: $0) } == true
    }

    /// Atomically writes `data` to `<directory>/<name>` (replacing an older artifact) and returns its URL.
    @discardableResult
    public func write(_ data: Data, named name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw Failure.invalidName(name) }
        guard !Self.isInside(directory, desktop, mirrored) else { throw Failure.insideDesktop(directory.path) }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }
}
