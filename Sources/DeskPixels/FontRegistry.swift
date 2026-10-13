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

    /// A small lock-protected dictionary for process-wide caches.
    final class LockedCache<K: Hashable, V>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [K: V] = [:]

        subscript(key: K) -> V? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        /// Stores `value` unless another thread got there first; returns the stored value.
        func insertIfAbsent(_ value: V, for key: K) -> V {
            lock.lock()
            defer { lock.unlock() }
            if let existing = storage[key] { return existing }
            storage[key] = value
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage.count
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            storage.removeAll()
        }
    }
}
