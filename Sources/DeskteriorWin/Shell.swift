#if os(Windows)
import DeskFiles
import Foundation
import WinSDK

/// Opening and revealing items through the shell (Explorer), the Windows side of `NSWorkspace.open` and
/// `activateFileViewerSelecting`. Nothing here changes a file; the file-safety lint allows the shell launch only in
/// this file.
enum Shell {
    /// Opens `url` with its default program (`ShellExecuteW` "open"), as a double-click in Explorer does.
    static func open(_ url: URL) {
        let path = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
        _ = "open".withCString(encodedAs: UTF16.self) { verb in
            path.withCString(encodedAs: UTF16.self) { file in ShellExecuteW(nil, verb, file, nil, nil, 1) }
        }
    }

    /// Opens the item's folder in Explorer with the item selected.
    static func reveal(_ url: URL) {
        let path = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
        guard let pidl = path.withCString(encodedAs: UTF16.self, { ILCreateFromPathW($0) }) else { return }
        defer { ILFree(pidl) }
        _ = SHOpenFolderAndSelectItems(pidl, 0, nil, 0)
    }
}
#endif
