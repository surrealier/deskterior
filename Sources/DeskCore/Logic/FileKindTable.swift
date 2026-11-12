import Foundation

/// File kinds by extension (docs/WINDOWS.md WP5): what `FileKindClassifier` decides from a `UTType` on macOS, as a
/// table for platforms without UTType. Pure. `FileKindTableTests` checks every entry against the UTType path on
/// macOS; the Windows-only extensions (exe, msi, msix, appx, lnk, ps1, bat, hwp…) are listed there with a reason.
public enum FileKindTable {
    /// Lowercase extension (no dot) → kind.
    public static let kinds: [String: FileKind] = {
        var table: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ exts: String) {
            for e in exts.split(separator: " ") { table[String(e)] = kind }
        }
        add(.doc, "doc docx pages rtf rtfd odt hwp hwpx xls xlsx ppt pptx key numbers ods odp")
        add(.text, "txt md markdown log csv")
        add(.pdf, "pdf")
        add(.image, "png jpg jpeg gif bmp webp heic heif tif tiff svg ico")
        add(.video, "mp4 m4v mov mkv avi webm wmv")
        add(.audio, "mp3 wav flac m4a aac ogg wma aif aiff")
        add(.zip, "zip 7z rar tar gz tgz bz2 xz")
        add(.code, "swift c h cpp hpp cs js ts py rs go java kt json xml yml yaml html htm css sh ps1 bat cmd plist")
        add(.app, "app exe msix appx")
        add(.dmg, "dmg iso img msi sparseimage sparsebundle")
        return table
    }()

    /// The kind for `ext` (any case, no dot); `.unknown` when the table has none.
    public static func kind(forExtension ext: String) -> FileKind {
        kinds[ext.lowercased()] ?? .unknown
    }

    /// A folder is `.folder`; a file goes by its extension, an image named like a screenshot (or captured) being
    /// `.screenshot`. A file with no known extension is `.unknown`.
    public static func classify(name: String, isDirectory: Bool, isScreenCapture: Bool = false) -> FileKind {
        let ext = (name as NSString).pathExtension
        if isDirectory {
            // Bundles a Windows desk can hold as folders still read as what they are.
            let k = kind(forExtension: ext)
            return k == .app || k == .doc ? k : .folder
        }
        let k = kind(forExtension: ext)
        if k == .image, isScreenCapture || looksLikeScreenshot(name) { return .screenshot }
        return k
    }

    /// System screenshot names (macOS in English and Korean, Windows' Snipping Tool and Print Screen).
    public static func looksLikeScreenshot(_ name: String) -> Bool {
        let n = TextLayout.nfc(name)
        return ["Screenshot ", "Screen Shot ", "스크린샷 ", "Screen Recording ", "Screenshot_", "스크린샷_"]
            .contains { n.hasPrefix($0) }
    }
}
