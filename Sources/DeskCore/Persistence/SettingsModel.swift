/// User settings (DESIGN §4.8), stored in `UserDefaults` under the bundle-id suite by the app. This type only
/// knows keys, defaults and value parsing; reading and writing go through closures so it stays pure.
public struct DeskSettings: Sendable, Equatable {
    public enum Key: String, CaseIterable, Sendable {
        case launchAtLogin, deskDisplayUUID, coverOtherDisplays, pixelSize, lights, iconStyle, dragOutMode,
             peekHotkeyEnabled, pauseOnBattery, reduceMotion, windowLevel, matMode, showDespiteFinderHidden,
             onboardingStep
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
        ]
    }
}
