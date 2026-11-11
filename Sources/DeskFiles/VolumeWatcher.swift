#if canImport(AppKit)
import AppKit
#elseif os(Windows)
import WinSDK
#endif
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

    #if canImport(AppKit)
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
    #else
    /// Lists once; afterwards the app calls `refresh()` when the system reports a drive change (`WM_DEVICECHANGE`
    /// on Windows), as the watcher itself makes no window.
    public func start() {
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.refresh() }
    }

    public func stop() {}
    #endif

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

    #if canImport(AppKit)
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
    #elseif os(Windows)
    /// The drives (`GetLogicalDrives`) Explorer's rules would show next to the desk, with `FinderPrefs`' defaults:
    /// removable and external drives, never the system drive or other internal ones unless asked.
    public static func visibleVolumes(prefs: FinderPrefs) -> [VolumeEntry] {
        let mask = GetLogicalDrives()
        var out: [VolumeEntry] = []
        for i in 0..<26 where mask & (1 << DWORD(i)) != 0 {
            let letter = String(UnicodeScalar(UInt8(ascii: "A") + UInt8(i)))
            let root = letter + #":\"#
            guard let facts = FilePrimitives.driveFacts(root), facts.isBrowsable else { continue }
            let kind = classify(facts)
            guard isShown(kind, prefs: prefs) else { continue }
            var label = [WCHAR](repeating: 0, count: 261)
            var serial: DWORD = 0
            _ = Win32.withWide(root) { GetVolumeInformationW($0, &label, DWORD(label.count), &serial, nil, nil, nil, 0) }
            let labelText = String(decoding: label.prefix { $0 != 0 }, as: UTF16.self)
            let name = labelText.isEmpty ? "\(letter):" : "\(labelText) (\(letter):)"
            out.append(VolumeEntry(
                id: FilePrimitives.hexVolume(UInt64(serial)), name: name, path: URL(fileURLWithPath: root).path, kind: kind,
                isEjectable: facts.isEjectable || facts.isRemovable || kind == .server
            ))
        }
        return out.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
    #else
    /// Linux (development only): no drive hub.
    public static func visibleVolumes(prefs: FinderPrefs) -> [VolumeEntry] { [] }
    #endif
}
