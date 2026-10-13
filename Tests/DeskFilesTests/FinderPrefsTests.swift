import DeskCore
import Foundation
import Testing
@testable import DeskFiles

@Suite("FinderPrefs and VolumeWatcher")
struct FinderPrefsTests {
    func prefs(_ values: [String: Any]) -> FinderPrefs {
        FinderPrefs.read { key, domain in values["\(domain).\(key)"] }
    }

    @Test("Spike S9: this Mac's values mean Finder shows desktop items")
    func s9Values() {
        let p = prefs([
            "com.apple.finder.ShowExternalHardDrivesOnDesktop": NSNumber(value: 1),
            "com.apple.finder.ShowRemovableMediaOnDesktop": NSNumber(value: 1),
            "com.apple.finder.ShowHardDrivesOnDesktop": NSNumber(value: 0),
            "com.apple.WindowManager.HideDesktop": NSNumber(value: 1),
        ])
        #expect(p.createDesktop == nil && p.standardHideDesktopIcons == nil && p.hideDesktop == true)
        #expect(!p.hidesDesktopItems, "HideDesktop only counts under Stage Manager")
        #expect(p.showsExternalHardDrives && p.showsRemovableMedia && !p.showsHardDrives && !p.showsMountedServers)
    }

    @Test("Finder hides items: CreateDesktop off, StandardHideDesktopIcons on, or HideDesktop under Stage Manager")
    func hidesItems() {
        #expect(prefs(["com.apple.finder.CreateDesktop": false]).hidesDesktopItems)
        #expect(prefs(["com.apple.finder.CreateDesktop": "0"]).hidesDesktopItems)
        #expect(!prefs(["com.apple.finder.CreateDesktop": true]).hidesDesktopItems)
        #expect(prefs(["com.apple.WindowManager.StandardHideDesktopIcons": NSNumber(value: true)]).hidesDesktopItems)
        #expect(prefs([
            "com.apple.WindowManager.HideDesktop": 1, "com.apple.WindowManager.GloballyEnabled": true,
        ]).hidesDesktopItems)
        #expect(!prefs(["com.apple.WindowManager.GloballyEnabled": true]).hidesDesktopItems)
        #expect(!prefs([:]).hidesDesktopItems)
    }

    @Test("Booleans parse from numbers, CFBoolean and strings")
    func booleans() {
        #expect(FinderPrefs.boolValue(kCFBooleanTrue) == true)
        #expect(FinderPrefs.boolValue(NSNumber(value: 0)) == false)
        #expect(FinderPrefs.boolValue("YES") == true && FinderPrefs.boolValue("no") == false)
        #expect(FinderPrefs.boolValue("maybe") == nil && FinderPrefs.boolValue(nil) == nil && FinderPrefs.boolValue([1]) == nil)
    }

    @Test("Reading the real preferences works and changes nothing")
    func realPrefs() {
        _ = FinderPrefs.current()
        #expect(FinderPrefs.finderDomain == "com.apple.finder")
    }

    @Test("Volume categories and Finder's filters")
    func volumes() {
        typealias W = VolumeWatcher
        #expect(W.classify(.init(isInternal: true, isLocal: true, isRemovable: false, isEjectable: false)) == .internalDisk)
        #expect(W.classify(.init(isInternal: false, isLocal: true, isRemovable: false, isEjectable: true)) == .removable)
        #expect(W.classify(.init(isInternal: false, isLocal: true, isRemovable: false, isEjectable: false)) == .externalDisk)
        #expect(W.classify(.init(isInternal: nil, isLocal: true, isRemovable: true, isEjectable: true)) == .removable)
        #expect(W.classify(.init(isInternal: nil, isLocal: false, isRemovable: false, isEjectable: true)) == .server)
        let defaults = FinderPrefs()
        #expect(!W.isShown(.internalDisk, prefs: defaults) && W.isShown(.externalDisk, prefs: defaults))
        #expect(W.isShown(.removable, prefs: defaults) && !W.isShown(.server, prefs: defaults))
        let all = FinderPrefs(showExternalHardDrives: true, showRemovableMedia: true, showMountedServers: true, showHardDrives: true)
        #expect(VolumeEntry.Kind.allCasesForTest.allSatisfy { W.isShown($0, prefs: all) })
    }

    @Test("Listing mounted volumes respects the filter")
    func listing() {
        let hidden = VolumeWatcher.visibleVolumes(prefs: FinderPrefs(
            showExternalHardDrives: false, showRemovableMedia: false, showMountedServers: false, showHardDrives: false
        ))
        #expect(hidden.isEmpty)
        let all = VolumeWatcher.visibleVolumes(prefs: FinderPrefs(showHardDrives: true))
        #expect(all.contains { $0.path == "/" && $0.kind == .internalDisk })
    }
}

extension VolumeEntry.Kind {
    static let allCasesForTest: [VolumeEntry.Kind] = [.internalDisk, .externalDisk, .removable, .server]
}
