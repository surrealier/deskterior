import DeskCore
import Foundation

// The app's side of the English/Korean string table (`L10n`, `L10nKey` in DeskCore): which language the app speaks,
// and a short spelling for its windows. Menus are translated by `MenuBridge`, toasts and monitor cards by the scene.

extension L10n {
    /// Speaks what the language setting asks for (the system's first preferred language for `system`).
    static func apply(_ setting: LanguageSetting) {
        L10n.language = setting.resolved(preferred: Locale.preferredLanguages)
    }
}

/// `key` in the current language (the app's windows).
func tr(_ key: L10nKey) -> String { L10n.text(key) }
