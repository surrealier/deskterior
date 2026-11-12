#if canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation

/// Loads fonts straight from file data (`CTFontManagerCreateFontDescriptorsFromData`), so nothing is
/// registered process-wide and the font is invisible to other code. Fonts are cached by (file, size).
public enum FontRegistry {
    private struct Key: Hashable {
        let path: String
        let size: Double
    }

    private static let cache = LockedCache<Key, CTFont>()

    /// The first face in the font file at `url`, at `size` px; nil when the file is missing or not a font.
    public static func font(at url: URL, size: CGFloat) -> CTFont? {
        let key = Key(path: url.standardizedFileURL.path, size: Double(size))
        if let hit = cache[key] { return hit }
        guard
            let data = try? Data(contentsOf: url),
            let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
            let first = descriptors.first
        else { return nil }
        let font = CTFontCreateWithFontDescriptor(first, size, nil)
        return cache.insertIfAbsent(font, for: key)
    }
}
#endif // canImport(CoreText)
