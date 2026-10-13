import DeskCore
import Foundation
import UniformTypeIdentifiers

/// Maps a file's type information to the `FileKind` that picks its kind icon (DESIGN §3.4). Pure: it reads
/// nothing from disk.
public enum FileKindClassifier {
    public static func classify(
        name: String, contentType: UTType?, isDirectory: Bool, isPackage: Bool, isScreenCapture: Bool = false
    ) -> FileKind {
        let ext = (name as NSString).pathExtension
        let type = contentType ?? (ext.isEmpty ? nil : UTType(filenameExtension: ext, conformingTo: isDirectory ? .package : .data))
        if isDirectory && !isPackage && !(type?.conforms(to: .package) ?? false) {
            return .folder
        }
        guard let type else { return isDirectory ? .folder : .unknown }

        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .app }
        if type.conforms(to: .image) {
            return isScreenCapture || looksLikeScreenshot(name) ? .screenshot : .image
        }
        if type.conforms(to: .diskImage) || ["dmg", "iso", "sparseimage", "sparsebundle"].contains(ext.lowercased()) {
            return .dmg
        }
        if type.conforms(to: .archive) || type.conforms(to: .zip) || type.conforms(to: .gzip)
            || type.conforms(to: .bz2) || ["7z", "rar", "xz", "tgz"].contains(ext.lowercased())
        {
            return .zip
        }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .html) || type.conforms(to: .yaml)
            || type.conforms(to: .propertyList)
        {
            return .code
        }
        if type.conforms(to: .rtf) || type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD)
            || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .compositeContent) || documentTypes.contains(where: type.conforms(to:))
        {
            return .doc
        }
        if type.conforms(to: .text) { return .text }
        if isDirectory { return .folder }
        return .unknown
    }

    /// Word, Pages and friends (not all have a `UTType` constant).
    private static let documentTypes: [UTType] = [
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages",
        "com.apple.iwork.pages.pages", "org.oasis-open.opendocument.text", "com.apple.iwork.keynote.sffkey",
        "com.apple.iwork.numbers.sffnumbers",
    ].compactMap { UTType($0) }

    /// System screenshot names (English and Korean, plus older "Screen Shot").
    public static func looksLikeScreenshot(_ name: String) -> Bool {
        let n = TextLayout.nfc(name)
        return ["Screenshot ", "Screen Shot ", "스크린샷 ", "Screen Recording "].contains { n.hasPrefix($0) }
    }
}
