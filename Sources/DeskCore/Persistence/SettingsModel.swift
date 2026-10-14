/// User settings (DESIGN §4.8), stored in `UserDefaults` under the bundle-id suite by the app. This type only
/// knows keys, defaults and value parsing; reading and writing go through closures so it stays pure.
public struct DeskSettings: Sendable, Equatable {
    public enum Key: String, CaseIterable, Sendable {
        case launchAtLogin, deskDisplayUUID, coverOtherDisplays, pixelSize, lights, iconStyle, dragOutMode,
             peekHotkeyEnabled, pauseOnBattery, reduceMotion, windowLevel, matMode, showDespiteFinderHidden,
             onboardingStep
        // MARK: system (M12)
        case language, mirroredFolder, loginItemVersion, translocationNoteShown, settingsVersion
    }

    public enum IconStyle: String, CaseIterable, Sendable {
        /// Pixelated real icons and thumbnails.
        case pixel
        /// Hand-drawn kind icons only.
        case kind
    }

    public enum DragOutMode: String, CaseIterable, Sendable {
        case finderLike, alwaysCopy
    }

    public enum ReduceMotion: String, CaseIterable, Sendable {
        case followSystem, on, off
    }

    public enum WindowLevel: String, CaseIterable, Sendable {
        case aboveIcons = "icon+1"
        case iconPlus3 = "icon+3"
    }

    public enum MatMode: String, CaseIterable, Sendable {
        case cloth, flat
    }

    /// Mirrors `SMAppService.mainApp`; only the toggle registers.
    public var launchAtLogin = false
    /// Nil: the menu-bar screen.
    public var deskDisplayUUID: String?
    /// Nil until asked in onboarding (only with more than one display).
    public var coverOtherDisplays: Bool?
    public var pixelSize: PixelSize = .normal
    public var lights: LightsMode = .auto
    public var iconStyle: IconStyle = .pixel
    public var dragOutMode: DragOutMode = .finderLike
    /// ⌃⌥⌘D Peek Desk; off by default.
    public var peekHotkeyEnabled = false
    public var pauseOnBattery = false
    public var reduceMotion: ReduceMotion = .followSystem
    public var windowLevel: WindowLevel = .aboveIcons
    public var matMode: MatMode = .cloth
    /// Nil until asked on the DESKTOP HIDDEN card.
    public var showDespiteFinderHidden: Bool?
    public var onboardingStep = 0
    // MARK: system (M12)
    /// Settings ▸ Language.
    public var language: LanguageSetting = .system
    /// Settings ▸ Mirrored folder (a path); nil mirrors the Desktop. Desk mode only (`--desktop-folder` wins).
    public var mirroredFolder: String?
    /// The app version that last registered the login item (it is registered again after an update, and only
    /// while `launchAtLogin` is on).
    public var loginItemVersion: String?
    /// The one-time "move to Applications" note (App Translocation) was shown.
    public var translocationNoteShown = false
    /// The settings layout these values were written in (`migrations`).
    public var settingsVersion = 0

    public init() {}

    /// Reads every key through `value` (e.g. `UserDefaults.object(forKey:)`); missing or malformed values
    /// keep their defaults.
    public init(reading value: (String) -> Any?) {
        func bool(_ k: Key) -> Bool? {
            switch value(k.rawValue) {
            case let b as Bool: b
            case let n as Int: n != 0
            case let s as String: ["1", "true", "yes"].contains(s.lowercased()) ? true
                : (["0", "false", "no"].contains(s.lowercased()) ? false : nil)
            default: nil
            }
        }
        func string(_ k: Key) -> String? { value(k.rawValue) as? String }
        func raw<T: RawRepresentable>(_ k: Key, _: T.Type) -> T? where T.RawValue == String {
            string(k).flatMap(T.init(rawValue:))
        }

        launchAtLogin = bool(.launchAtLogin) ?? false
        deskDisplayUUID = string(.deskDisplayUUID)
        coverOtherDisplays = bool(.coverOtherDisplays)
        pixelSize = raw(.pixelSize, PixelSize.self) ?? .normal
        lights = raw(.lights, LightsMode.self) ?? .auto
        iconStyle = raw(.iconStyle, IconStyle.self) ?? .pixel
        dragOutMode = raw(.dragOutMode, DragOutMode.self) ?? .finderLike
        peekHotkeyEnabled = bool(.peekHotkeyEnabled) ?? false
        pauseOnBattery = bool(.pauseOnBattery) ?? false
        reduceMotion = raw(.reduceMotion, ReduceMotion.self) ?? .followSystem
        windowLevel = raw(.windowLevel, WindowLevel.self) ?? .aboveIcons
        matMode = raw(.matMode, MatMode.self) ?? .cloth
        showDespiteFinderHidden = bool(.showDespiteFinderHidden)
        onboardingStep = max(0, (value(Key.onboardingStep.rawValue) as? Int) ?? 0)
        language = raw(.language, LanguageSetting.self) ?? .system
        mirroredFolder = string(.mirroredFolder).flatMap { $0.isEmpty ? nil : $0 }
        loginItemVersion = string(.loginItemVersion)
        translocationNoteShown = bool(.translocationNoteShown) ?? false
        settingsVersion = max(0, (value(Key.settingsVersion.rawValue) as? Int) ?? 0)
    }

    /// Property-list values per key (`nil` = remove the key, i.e. back to "unset").
    public var propertyList: [(key: String, value: (any Sendable)?)] {
        [
            (Key.launchAtLogin.rawValue, launchAtLogin),
            (Key.deskDisplayUUID.rawValue, deskDisplayUUID),
            (Key.coverOtherDisplays.rawValue, coverOtherDisplays),
            (Key.pixelSize.rawValue, pixelSize.rawValue),
            (Key.lights.rawValue, lights.rawValue),
            (Key.iconStyle.rawValue, iconStyle.rawValue),
            (Key.dragOutMode.rawValue, dragOutMode.rawValue),
            (Key.peekHotkeyEnabled.rawValue, peekHotkeyEnabled),
            (Key.pauseOnBattery.rawValue, pauseOnBattery),
            (Key.reduceMotion.rawValue, reduceMotion.rawValue),
            (Key.windowLevel.rawValue, windowLevel.rawValue),
            (Key.matMode.rawValue, matMode.rawValue),
            (Key.showDespiteFinderHidden.rawValue, showDespiteFinderHidden),
            (Key.onboardingStep.rawValue, onboardingStep),
            (Key.language.rawValue, language.rawValue),
            (Key.mirroredFolder.rawValue, mirroredFolder),
            (Key.loginItemVersion.rawValue, loginItemVersion),
            (Key.translocationNoteShown.rawValue, translocationNoteShown),
            (Key.settingsVersion.rawValue, settingsVersion),
        ]
    }

    /// The value `propertyList` writes for `key`.
    public func value(for key: Key) -> (any Sendable)? {
        propertyList.first { $0.key == key.rawValue }?.value ?? nil
    }

    // MARK: Migrations (M12)

    /// The settings layout this build writes.
    public static let currentVersion = 1

    /// The writes that bring settings stored by an older build up to `currentVersion` (`nil` removes a key), read
    /// through `value` like `init(reading:)`. Running them again finds nothing to do. Version 0 → 1 keeps what the
    /// user meant where an older spelling would otherwise fall back to the default:
    /// - `lights` "lampOnly" → "lamp" (Errata 9);
    /// - `reduceMotion` stored as a switch → "on" / "followSystem";
    /// - `pixelSize` stored as the target height 320 / 380 / 440 → chunky / normal / fine;
    /// - `windowLevel` stored by case name ("aboveIcons", "iconPlus3") → "icon+1" / "icon+3";
    /// - `onboardingStep` and `settingsVersion` stored as text → numbers.
    /// A newer `settingsVersion` is left alone.
    public static func migrations(reading value: (String) -> Any?) -> [(key: String, value: (any Sendable)?)] {
        let version = (value(Key.settingsVersion.rawValue) as? Int)
            ?? (value(Key.settingsVersion.rawValue) as? String).flatMap { Int($0) } ?? 0
        guard version < currentVersion else { return [] }
        var out: [(key: String, value: (any Sendable)?)] = []
        func put(_ k: Key, _ v: (any Sendable)?) { out.append((k.rawValue, v)) }
        if (value(Key.lights.rawValue) as? String) == "lampOnly" { put(.lights, LightsMode.lampOnly.rawValue) }
        if let on = value(Key.reduceMotion.rawValue) as? Bool {
            put(.reduceMotion, (on ? ReduceMotion.on : .followSystem).rawValue)
        }
        if let n = (value(Key.pixelSize.rawValue) as? Int)
            ?? (value(Key.pixelSize.rawValue) as? String).flatMap({ Int($0) }) {
            let size = PixelSize.allCases.first { $0.targetArtHeight == n } ?? .normal
            put(.pixelSize, size.rawValue)
        }
        switch value(Key.windowLevel.rawValue) as? String {
        case "aboveIcons": put(.windowLevel, WindowLevel.aboveIcons.rawValue)
        case "iconPlus3": put(.windowLevel, WindowLevel.iconPlus3.rawValue)
        default: break
        }
        if let s = value(Key.onboardingStep.rawValue) as? String { put(.onboardingStep, max(0, Int(s) ?? 0)) }
        put(.settingsVersion, currentVersion)
        return out
    }
}
