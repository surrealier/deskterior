import AppKit
import DeskCore
import Foundation

/// Mounted volumes that Finder would show on the desktop (drive hub, DESIGN §2.2 E15), refreshed on
/// `NSWorkspace.didMount` / `didUnmount` / `didRenameVolume`. Read-only.
public final class VolumeWatcher: @unchecked Sendable {
    private let handler: @Sendable ([VolumeEntry]) -> Void
    private let prefs: @Sendable () -> FinderPrefs
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    /// `handler` gets the filtered list on start and after every mount change (on a background queue).
    public init(
        prefs: @escaping @Sendable () -> FinderPrefs = { FinderPrefs.current() },
        handler: @escaping @Sendable ([VolumeEntry]) -> Void
    ) {
        self.prefs = prefs
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification,
        ]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: queue) { [weak self] _ in self?.refresh() }
        }
        lock.withLock { observers += tokens }
        queue.addOperation { [weak self] in self?.refresh() }
    }

    public func stop() {
        let tokens = lock.withLock {
            defer { observers = [] }
            return observers
        }
        for t in tokens { NSWorkspace.shared.notificationCenter.removeObserver(t) }
    }

    /// Lists and filters the mounted volumes now.
    public func refresh() {
        handler(Self.visibleVolumes(prefs: prefs()))
    }

    // MARK: Listing

    static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsLocalKey,
        .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
    ]

    /// Raw facts about one mounted volume, for `classify`.
    public struct Facts: Sendable, Equatable {
        public var isInternal: Bool?
        public var isLocal: Bool
        public var isRemovable: Bool
        public var isEjectable: Bool
        public var isBrowsable: Bool
        public var isRoot: Bool

        public init(
            isInternal: Bool?, isLocal: Bool, isRemovable: Bool, isEjectable: Bool, isBrowsable: Bool = true,
            isRoot: Bool = false
        ) {
            self.isInternal = isInternal
            self.isLocal = isLocal
            self.isRemovable = isRemovable
            self.isEjectable = isEjectable
            self.isBrowsable = isBrowsable
            self.isRoot = isRoot
        }
    }

    /// Finder's category for a volume.
    public static func classify(_ f: Facts) -> VolumeEntry.Kind {
        if !f.isLocal { return .server }
        if f.isRemovable || (f.isEjectable && f.isInternal != true) { return .removable }
        if f.isInternal == false { return .externalDisk }
        return .internalDisk
    }

    /// Whether Finder shows a volume of `kind` on the desktop under `prefs`.
    public static func isShown(_ kind: VolumeEntry.Kind, prefs: FinderPrefs) -> Bool {
        switch kind {
        case .internalDisk: prefs.showsHardDrives
        case .externalDisk: prefs.showsExternalHardDrives
        case .removable: prefs.showsRemovableMedia
        case .server: prefs.showsMountedServers
        }
    }

    /// Browsable mounted volumes Finder would show, sorted by name.
    public static func visibleVolumes(prefs: FinderPrefs) -> [VolumeEntry] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: resourceKeys, options: [.skipHiddenVolumes]
        ) ?? []
        var out: [VolumeEntry] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(resourceKeys)) else { continue }
            let facts = Facts(
                isInternal: v.volumeIsInternal, isLocal: v.volumeIsLocal ?? true, isRemovable: v.volumeIsRemovable ?? false,
                isEjectable: v.volumeIsEjectable ?? false, isBrowsable: v.volumeIsBrowsable ?? true,
                isRoot: v.volumeIsRootFileSystem ?? false
            )
            guard facts.isBrowsable else { continue }
            let kind = classify(facts)
            guard isShown(kind, prefs: prefs) else { continue }
            out.append(VolumeEntry(
                id: v.volumeUUIDString ?? url.path, name: v.volumeLocalizedName ?? v.volumeName ?? url.lastPathComponent,
                path: url.path, kind: kind, isEjectable: facts.isEjectable || facts.isRemovable || kind == .server
            ))
        }
        return out.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}
