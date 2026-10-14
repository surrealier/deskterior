import DeskCore
import Foundation

/// Leftovers of drop-in copies cut short by a quit or a crash (DESIGN §3.6, Errata 25). When the system offers no
/// item-replacement folder on the desk's volume, `FileOperator` stages a copy in a hidden `.deskterior-partial-<uuid>`
/// folder in the desk folder, and removes it itself only while that copy runs. A folder left over from an earlier run
/// is never touched automatically: `find` lists them (the desk folder's top level only; it reads, never writes), the
/// app logs them and says so once, Settings offers Show in Finder, and only an explicit Move to Trash there takes
/// them away (`FileOperator.trash`, with a menu intent, into the Trash).
public enum PartialCopies {
    /// One leftover staging folder.
    public struct Leftover: Sendable, Equatable {
        public var url: URL
        /// Its identity when found; the trash re-checks it right before acting.
        public var key: TokenKey
        /// What lies inside (the copy that never landed), for Show in Finder.
        public var contents: [URL]

        public init(url: URL, key: TokenKey, contents: [URL]) {
            self.url = url
            self.key = key
            self.contents = contents
        }
    }

    /// `.deskterior-partial-` followed by a UUID: the only names `FileOperator` stages under.
    public static func isLeftoverName(_ name: String) -> Bool {
        guard name.hasPrefix(FileMoves.partialPrefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(FileMoves.partialPrefix.count))) != nil
    }

    /// The leftover staging folders directly inside `root` (real folders, not symlinks), by name. Read-only; nothing
    /// below the top level is listed except each leftover's own items.
    public static func find(in root: URL) -> [Leftover] {
        let folder = URL(fileURLWithPath: DesktopLocator.canonicalPath(root), isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(isLeftoverName).sorted().compactMap { name in
            let url = folder.appendingPathComponent(name, isDirectory: false)
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, let key = FileReport.identity(of: url) else {
                return nil
            }
            let inside = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
            return Leftover(url: url, key: key, contents: inside.map { url.appendingPathComponent($0, isDirectory: false) })
        }
    }
}
