import Foundation

/// The identity of a desktop item: its volume and inode (DESIGN §3.2). This is the only `Hashable` identity
/// in the model; names, kinds and dates are mutable `TokenMeta`, so a rename keeps the token.
public struct TokenKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    /// `URLResourceValues.volumeUUIDString` of the item's volume.
    public var volume: String
    /// `URLResourceValues.fileIdentifier` (the inode on APFS/HFS+).
    public var inode: UInt64

    public init(volume: String, inode: UInt64) {
        self.volume = volume
        self.inode = inode
    }

    public static func < (a: TokenKey, b: TokenKey) -> Bool {
        a.volume != b.volume ? a.volume < b.volume : a.inode < b.inode
    }

    public var description: String { "\(volume.prefix(8))/\(inode)" }
}

/// What a token looks like (kind icon, pen-cap colour, folder-tab colour). DESIGN §3.4.
public enum FileKind: String, Codable, CaseIterable, Sendable {
    case folder, doc, text, pdf, image, video, audio, zip, app, code, dmg, screenshot, unknown

    /// Unknown raw values decode as `.unknown`, so newer documents still load.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FileKind(rawValue: raw) ?? .unknown
    }

    /// Kinds that get a photo-style thumbnail.
    public var isImageLike: Bool { self == .image || self == .screenshot }
}

/// Mutable facts about a token's file. `displayName` is always the NFC form of `name`; matching uses the raw
/// `name` and the key. Dates are kept to whole milliseconds (what `desk.json` stores), so a reloaded layout
/// compares equal to a fresh scan.
public struct TokenMeta: Codable, Sendable, Equatable {
    /// The file name as stored on disk (may be NFD).
    public var name: String {
        didSet { displayName = TextLayout.nfc(name) }
    }
    /// `name` in NFC, for drawing and search.
    public private(set) var displayName: String
    public var kind: FileKind
    public var added: Date?
    public var modified: Date?
    /// Creation date: survives renames, safe-saves and copies, so it corroborates a returning file.
    public var created: Date?
    public var size: Int64?
    public var tags: [String]
    public var isPackage: Bool
    /// An iCloud item whose content is not local; it gets the kind icon only and is never read.
    public var isDataless: Bool
    public var isAlias: Bool
    /// Finder hides the extension of this file.
    public var hidesExtension: Bool

    public init(
        name: String, kind: FileKind, added: Date? = nil, modified: Date? = nil, created: Date? = nil,
        size: Int64? = nil, tags: [String] = [], isPackage: Bool = false, isDataless: Bool = false,
        isAlias: Bool = false, hidesExtension: Bool = false
    ) {
        self.name = name
        self.displayName = TextLayout.nfc(name)
        self.kind = kind
        self.added = added.map(ISODate.wholeMilliseconds)
        self.modified = modified.map(ISODate.wholeMilliseconds)
        self.created = created.map(ISODate.wholeMilliseconds)
        self.size = size
        self.tags = tags
        self.isPackage = isPackage
        self.isDataless = isDataless
        self.isAlias = isAlias
        self.hidesExtension = hidesExtension
    }

    /// Raw names compare by scalars, so an NFD → NFC respelling on disk counts as a change and is stored.
    public static func == (a: TokenMeta, b: TokenMeta) -> Bool {
        a.name.unicodeScalars.elementsEqual(b.name.unicodeScalars) && a.kind == b.kind && a.added == b.added
            && a.modified == b.modified && a.created == b.created && a.size == b.size && a.tags == b.tags
            && a.isPackage == b.isPackage && a.isDataless == b.isDataless && a.isAlias == b.isAlias
            && a.hidesExtension == b.hidesExtension
    }

    private enum CodingKeys: String, CodingKey {
        case name, kind, added, modified, created, size, tags, isPackage, isDataless, isAlias, hidesExtension
    }

    /// Only `name` is required; everything else defaults (schema-1 documents list just name, kind and added).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decode(String.self, forKey: .name),
            kind: try c.decodeIfPresent(FileKind.self, forKey: .kind) ?? .unknown,
            added: try c.decodeIfPresent(Date.self, forKey: .added),
            modified: try c.decodeIfPresent(Date.self, forKey: .modified),
            created: try c.decodeIfPresent(Date.self, forKey: .created),
            size: try c.decodeIfPresent(Int64.self, forKey: .size),
            tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
            isPackage: try c.decodeIfPresent(Bool.self, forKey: .isPackage) ?? false,
            isDataless: try c.decodeIfPresent(Bool.self, forKey: .isDataless) ?? false,
            isAlias: try c.decodeIfPresent(Bool.self, forKey: .isAlias) ?? false,
            hidesExtension: try c.decodeIfPresent(Bool.self, forKey: .hidesExtension) ?? false
        )
    }

    /// Writes only non-default fields (`displayName` is derived and never written).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(added, forKey: .added)
        try c.encodeIfPresent(modified, forKey: .modified)
        try c.encodeIfPresent(created, forKey: .created)
        try c.encodeIfPresent(size, forKey: .size)
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
        if isPackage { try c.encode(true, forKey: .isPackage) }
        if isDataless { try c.encode(true, forKey: .isDataless) }
        if isAlias { try c.encode(true, forKey: .isAlias) }
        if hidesExtension { try c.encode(true, forKey: .hidesExtension) }
    }
}

/// One top-level item of the desktop folder as the scanner saw it.
public struct DesktopEntry: Sendable, Equatable {
    public var key: TokenKey
    public var meta: TokenMeta

    public init(key: TokenKey, meta: TokenMeta) {
        self.key = key
        self.meta = meta
    }
}

/// A complete listing of the desktop folder's visible top-level items (DESIGN §3.1 item 3).
public struct DesktopSnapshot: Sendable, Equatable {
    /// Standardized path of the mirrored folder.
    public var rootPath: String
    /// Volume UUID of the mirrored folder.
    public var rootVolume: String
    /// Entries sorted by raw name.
    public var entries: [DesktopEntry]
    public var scannedAt: Date
    /// The scan follows the previous one under an uninterrupted watch, so every change it shows happened within
    /// one watcher batch before `scannedAt`. False for a first scan (launch), a rescan on request, and the scan
    /// after dropped events or a root change: then nothing is known about when files vanished.
    public var continuous: Bool

    public init(rootPath: String, rootVolume: String, entries: [DesktopEntry], scannedAt: Date, continuous: Bool = false) {
        self.rootPath = rootPath
        self.rootVolume = rootVolume
        self.entries = entries
        self.scannedAt = scannedAt
        self.continuous = continuous
    }
}

/// A mounted volume that Finder would show on the desktop (drive hub, DESIGN §2.2 E15).
public struct VolumeEntry: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case internalDisk, externalDisk, removable, server
    }

    /// Volume UUID when known, else the mount path.
    public var id: String
    public var name: String
    public var path: String
    public var kind: Kind
    public var isEjectable: Bool

    public init(id: String, name: String, path: String, kind: Kind, isEjectable: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.isEjectable = isEjectable
    }
}
