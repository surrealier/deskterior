import DeskCore
import Foundation

// The app's side of the English/Korean string table (`L10n`, `L10nKey` in DeskCore): which language the app speaks,
// and a short spelling for its windows. Menus are translated by `MenuBridge`, toasts and monitor cards by the scene.

extension L10n {
    /// Speaks what the language setting asks for (for `system`, the first of the system's preferred languages that
    /// the app speaks).
    static func apply(_ setting: LanguageSetting) {
        L10n.language = setting.resolved(preferred: Locale.preferredLanguages)
    }

    /// Dates in the language the app speaks (`Language.dateLocale`).
    static var locale: Locale { language.dateLocale(current: .current) }
}

/// `key` in the current language (the app's windows).
func tr(_ key: L10nKey) -> String { L10n.text(key) }
