import Foundation
import Testing
@testable import DeskCore

/// `DeskSettings` (DESIGN §4.8; M12): defaults, round trips through property-list values, and the migration of
/// settings written by older builds.
@Suite("Settings")
struct SettingsModelTests {
    /// A property-list store, as `UserDefaults` would hold it.
    private static func store(_ s: DeskSettings) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in s.propertyList { if let v { out[k] = v } }
        return out
    }

    private static func apply(_ writes: [(key: String, value: (any Sendable)?)], to d: inout [String: Any]) {
        for (k, v) in writes { d[k] = v }
    }

    @Test("Defaults: hotkey and launch at login off, the system's language, the Desktop, nothing asked yet")
    func defaults() {
        let s = DeskSettings(reading: { _ in nil })
        #expect(s == DeskSettings())
        #expect(!s.launchAtLogin && !s.peekHotkeyEnabled && !s.pauseOnBattery)
        #expect(s.language == .system && s.mirroredFolder == nil && s.coverOtherDisplays == nil)
        #expect(s.loginItemVersion == nil && !s.translocationNoteShown && s.onboardingStep == 0)
        #expect(s.reduceMotion == .followSystem && s.matMode == .cloth && s.lights == .auto)
    }

    @Test("Every field survives a round trip through property-list values")
    func roundTrip() {
        var s = DeskSettings()
        s.launchAtLogin = true
        s.deskDisplayUUID = "37D8-UUID"
        s.coverOtherDisplays = false
        s.pixelSize = .fine
        s.lights = .lampOnly
        s.iconStyle = .kind
        s.dragOutMode = .alwaysCopy
        s.peekHotkeyEnabled = true
        s.pauseOnBattery = true
        s.reduceMotion = .on
        s.windowLevel = .iconPlus3
        s.matMode = .flat
        s.showDespiteFinderHidden = true
        s.onboardingStep = 2
        s.language = .ko
        s.mirroredFolder = "/Users/x/Work"
        s.loginItemVersion = "0.1.0 42"
        s.translocationNoteShown = true
        s.settingsVersion = DeskSettings.currentVersion
        let d = Self.store(s)
        #expect(DeskSettings(reading: { d[$0] }) == s)
        #expect(Set(s.propertyList.map(\.key)) == Set(DeskSettings.Key.allCases.map(\.rawValue)))
        #expect(s.value(for: .language) as? String == "ko")
    }

    @Test("Malformed values keep their defaults; an empty folder is the Desktop")
    func malformed() {
        let d: [String: Any] = ["language": "fr", "mirroredFolder": "", "launchAtLogin": "maybe", "onboardingStep": -3]
        let s = DeskSettings(reading: { d[$0] })
        #expect(s.language == .system && s.mirroredFolder == nil && !s.launchAtLogin && s.onboardingStep == 0)
    }

    @Test("Migration 0 → 1 keeps what older spellings meant, and runs once")
    func migrate() {
        var d: [String: Any] = [
            "lights": "lampOnly", "reduceMotion": true, "pixelSize": 440, "windowLevel": "iconPlus3", "onboardingStep": "3",
            "launchAtLogin": true,
        ]
        let before = DeskSettings(reading: { d[$0] })
        #expect(before.lights == .auto && before.reduceMotion == .followSystem && before.pixelSize == .normal)
        Self.apply(DeskSettings.migrations(reading: { d[$0] }), to: &d)
        let s = DeskSettings(reading: { d[$0] })
        #expect(s.lights == .lampOnly && s.reduceMotion == .on && s.pixelSize == .fine && s.windowLevel == .iconPlus3)
        #expect(s.onboardingStep == 3 && s.launchAtLogin && s.settingsVersion == DeskSettings.currentVersion)
        // Nothing left to do.
        #expect(DeskSettings.migrations(reading: { d[$0] }).isEmpty)
        // A switch that was off means "follow the system"; 320 is chunky; the old case name of icon+1.
        var e: [String: Any] = ["reduceMotion": false, "pixelSize": "320", "windowLevel": "aboveIcons"]
        Self.apply(DeskSettings.migrations(reading: { e[$0] }), to: &e)
        let t = DeskSettings(reading: { e[$0] })
        #expect(t.reduceMotion == .followSystem && t.pixelSize == .chunky && t.windowLevel == .aboveIcons)
    }

    @Test("Current and newer settings are left alone; fresh settings only get their version")
    func noMigration() {
        let current: [String: Any] = ["settingsVersion": DeskSettings.currentVersion, "lights": "lampOnly"]
        #expect(DeskSettings.migrations(reading: { current[$0] }).isEmpty)
        let newer: [String: Any] = ["settingsVersion": DeskSettings.currentVersion + 5, "reduceMotion": true]
        #expect(DeskSettings.migrations(reading: { newer[$0] }).isEmpty)
        let fresh = DeskSettings.migrations(reading: { _ in nil })
        #expect(fresh.count == 1 && fresh[0].key == "settingsVersion" && fresh[0].value as? Int == DeskSettings.currentVersion)
    }

    @Test("The settings domain: the app's own inside the .app, the fallback suite when unbundled, never a suite named after the app")
    func domain() {
        #expect(DeskSettings.suiteName(bundleIdentifier: "io.github.someone.deskterior", fallback: "io.github.deskterior.dev") == nil)
        #expect(DeskSettings.suiteName(bundleIdentifier: nil, fallback: "io.github.deskterior.dev") == "io.github.deskterior.dev")
        // Why: macOS refuses a suite named after the running app's own bundle id (nothing would ever be saved).
        if let own = Bundle.main.bundleIdentifier {
            #expect(UserDefaults(suiteName: own) == nil)
            #expect(DeskSettings.suiteName(bundleIdentifier: own, fallback: "x") != own)
        }
    }
}
