import CoreFoundation
import Foundation

/// Read-only Finder and WindowManager preferences (DESIGN §3.1 item 2, §2.2 E15; spike S9). Deskterior never
/// writes these domains.
public struct FinderPrefs: Sendable, Equatable {
    public static let finderDomain = "com.apple.finder"
    public static let windowManagerDomain = "com.apple.WindowManager"

    /// Raw values; nil = unset.
    public var createDesktop: Bool?
    public var standardHideDesktopIcons: Bool?
    /// Stage Manager's "show items" toggle (inverted): consulted only while Stage Manager is on.
    public var hideDesktop: Bool?
    /// Stage Manager is on.
    public var stageManager: Bool?
    public var showExternalHardDrives: Bool?
    public var showRemovableMedia: Bool?
    public var showMountedServers: Bool?
    public var showHardDrives: Bool?

    public init(
        createDesktop: Bool? = nil, standardHideDesktopIcons: Bool? = nil, hideDesktop: Bool? = nil,
        stageManager: Bool? = nil, showExternalHardDrives: Bool? = nil, showRemovableMedia: Bool? = nil,
        showMountedServers: Bool? = nil, showHardDrives: Bool? = nil
    ) {
        self.createDesktop = createDesktop
        self.standardHideDesktopIcons = standardHideDesktopIcons
        self.hideDesktop = hideDesktop
        self.stageManager = stageManager
        self.showExternalHardDrives = showExternalHardDrives
        self.showRemovableMedia = showRemovableMedia
        self.showMountedServers = showMountedServers
        self.showHardDrives = showHardDrives
    }

    /// Finder hides desktop items: `CreateDesktop == false`, or `StandardHideDesktopIcons == true`, or — only
    /// with Stage Manager on — `HideDesktop == true`.
    public var hidesDesktopItems: Bool {
        createDesktop == false || standardHideDesktopIcons == true || (stageManager == true && hideDesktop == true)
    }

    /// Volume filters with Finder's defaults for unset keys (external and removable on, servers and internal
    /// disks off).
    public var showsExternalHardDrives: Bool { showExternalHardDrives ?? true }
    public var showsRemovableMedia: Bool { showRemovableMedia ?? true }
    public var showsMountedServers: Bool { showMountedServers ?? false }
    public var showsHardDrives: Bool { showHardDrives ?? false }

    /// Reads the current values through `CFPreferencesCopyAppValue`.
    public static func current() -> FinderPrefs {
        read { key, domain in CFPreferencesCopyAppValue(key as CFString, domain as CFString) }
    }

    /// Reads through `lookup(key, domain)` (injectable for tests).
    public static func read(_ lookup: (String, String) -> Any?) -> FinderPrefs {
        func flag(_ key: String, _ domain: String) -> Bool? { boolValue(lookup(key, domain)) }
        return FinderPrefs(
            createDesktop: flag("CreateDesktop", finderDomain),
            standardHideDesktopIcons: flag("StandardHideDesktopIcons", windowManagerDomain),
            hideDesktop: flag("HideDesktop", windowManagerDomain),
            stageManager: flag("GloballyEnabled", windowManagerDomain),
            showExternalHardDrives: flag("ShowExternalHardDrivesOnDesktop", finderDomain),
            showRemovableMedia: flag("ShowRemovableMediaOnDesktop", finderDomain),
            showMountedServers: flag("ShowMountedServersOnDesktop", finderDomain),
            showHardDrives: flag("ShowHardDrivesOnDesktop", finderDomain)
        )
    }

    /// Booleans come as CFBoolean, numbers or strings ("1", "true", "YES"…) depending on who wrote them.
    static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let n as NSNumber: n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "1", "true", "yes": true
            case "0", "false", "no": false
            default: nil
            }
        default: nil
        }
    }
}
