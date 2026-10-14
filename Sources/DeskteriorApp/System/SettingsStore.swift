import AppKit
import DeskCore

/// Where the user's settings live (DESIGN §4.8): the app's defaults (`AppIdentity.defaults`) in desk mode, and memory
/// in every other mode, so a `--windowed`, headless or demo run never reads or changes the real app's settings. Older
/// values are migrated once when the store opens (`DeskSettings.migrations`). Observers hear every change. Every
/// setting the app keeps goes through here (the mirrored folder and "show them anyway" included).
final class SettingsStore {
    private let defaults: UserDefaults?
    private var memory: [String: Any]
    private(set) var settings: DeskSettings
    private var observers: [(DeskSettings, DeskSettings) -> Void] = []

    /// The real settings (desk mode).
    init(defaults: UserDefaults) {
        self.defaults = defaults
        memory = [:]
        for (key, value) in DeskSettings.migrations(reading: { defaults.object(forKey: $0) }) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        settings = DeskSettings(reading: { defaults.object(forKey: $0) })
    }

    /// Throwaway settings (development modes, tests), starting from `values`.
    init(memory values: [String: Any] = [:]) {
        defaults = nil
        memory = values
        for (key, value) in DeskSettings.migrations(reading: { values[$0] }) { memory[key] = value }
        let snapshot = memory
        settings = DeskSettings(reading: { snapshot[$0] })
    }

    /// The store for a launch: desk mode keeps settings in the app's defaults; everything else in memory.
    static func forLaunch(_ options: LaunchOptions) -> SettingsStore {
        if options.mode == .desk { return SettingsStore(defaults: AppIdentity.defaults) }
        // Development runs speak English unless --language says otherwise, so their screenshots stay stable.
        return SettingsStore(memory: [DeskSettings.Key.language.rawValue: (options.language ?? .en).rawValue])
    }

    var isPersistent: Bool { defaults != nil }

    /// Calls `body(new, old)` after every change.
    func observe(_ body: @escaping (DeskSettings, DeskSettings) -> Void) {
        observers.append(body)
    }

    /// Changes settings and writes the keys that changed.
    func update(_ body: (inout DeskSettings) -> Void) {
        let old = settings
        body(&settings)
        guard settings != old else { return }
        let before = Dictionary(old.propertyList.map { ($0.key, $0.value.map { "\($0)" }) }, uniquingKeysWith: { a, _ in a })
        for (key, value) in settings.propertyList where before[key] != value.map({ "\($0)" }) {
            write(key, value)
        }
        for o in observers { o(settings, old) }
    }

    private func write(_ key: String, _ value: (any Sendable)?) {
        if let defaults {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        } else {
            memory[key] = value
        }
    }
}
