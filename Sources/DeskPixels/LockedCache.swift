import Foundation

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
