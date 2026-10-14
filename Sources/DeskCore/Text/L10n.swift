import Foundation

/// A language the app speaks (DESIGN §4.1 "strings"; M12).
public enum Language: String, CaseIterable, Sendable {
    case en, ko
}

/// The language setting: follow the system, or a fixed language (Settings ▸ Language).
public enum LanguageSetting: String, CaseIterable, Sendable, Codable {
    case system, en, ko

    /// The language this setting speaks, given the system's preferred languages (`Locale.preferredLanguages`):
    /// `system` is Korean when the first preferred language is Korean, otherwise English.
    public func resolved(preferred: [String]) -> Language {
        switch self {
        case .en: .en
        case .ko: .ko
        case .system: preferred.first.map { $0.lowercased().hasPrefix("ko") } == true ? .ko : .en
        }
    }
}

/// English and Korean strings from one table (`L10nKey`), no asset catalogs or `.strings` files (they need Xcode's
/// tooling to be useful): `L10n.text(key)` for the app's own UI, and `L10n.tr(english)` for text built elsewhere in
/// English (menu titles from `MenuSpec`, toasts, monitor cards), which matches the table's English exactly or a
/// template (`%d` a number, `%@` text kept as it is, `%T` text that is translated too). Anything the table does not
/// know is shown as it is. The current language is process-wide; tests, headless runs and demos speak English unless
/// they ask otherwise, so snapshots stay stable.
public enum L10n {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var language = Language.en
    }

    private static let box = Box()

    /// The language strings are produced in now.
    public static var language: Language {
        get { box.lock.withLock { box.language } }
        set { box.lock.withLock { box.language = newValue } }
    }

    /// `key` in the current language (or `language`).
    public static func text(_ key: L10nKey, _ language: Language? = nil) -> String {
        let l = language ?? Self.language
        return l == .ko ? key.ko : key.en
    }

    /// A template key filled with `args` in order (`%d` takes an Int, `%@`/`%T` a String; `%T` is translated).
    public static func format(_ key: L10nKey, _ args: [any Sendable], _ language: Language? = nil) -> String {
        let l = language ?? Self.language
        return fill(l == .ko ? key.ko : key.en, args.map { arg in
            if let s = arg as? String { return s }
            return "\(arg)"
        }, language: l)
    }

    /// English text built elsewhere, in the current language (or `language`): an exact table match, then the
    /// first template that matches the whole string, else the text unchanged.
    public static func tr(_ english: String, _ language: Language? = nil) -> String {
        let l = language ?? Self.language
        guard l != .en else { return english }
        return translate(english, l) ?? english
    }

    /// Whether `tr` knows `english` (exactly or through a template).
    public static func knows(_ english: String) -> Bool {
        translate(english, .ko) != nil
    }

    // MARK: Matching

    private static func translate(_ english: String, _ l: Language) -> String? {
        if let key = index.exact[english] { return text(key, l) }
        for t in index.templates {
            guard let args = t.match(english) else { continue }
            return fill(text(t.key, l), args, language: l)
        }
        return nil
    }

    /// Replaces the placeholders of `template` in order; `%T` arguments are translated first.
    static func fill(_ template: String, _ args: [String], language l: Language) -> String {
        var out = ""
        var i = template.startIndex
        var n = 0
        while i < template.endIndex {
            let c = template[i]
            let next = template.index(after: i)
            if c == "%", next < template.endIndex, "d@T".contains(template[next]) {
                let arg = n < args.count ? args[n] : ""
                out += template[next] == "T" ? tr(arg, l) : arg
                n += 1
                i = template.index(after: next)
            } else {
                out.append(c)
                i = next
            }
        }
        return out
    }

    /// The placeholders of a template, in order (`d`, `@`, `T`).
    public static func placeholders(_ template: String) -> [Character] {
        var out: [Character] = []
        var it = template.makeIterator()
        while let c = it.next() {
            guard c == "%", let p = it.next() else { continue }
            if "d@T".contains(p) { out.append(p) }
        }
        return out
    }

    private struct Template: Sendable {
        let key: L10nKey
        let regex: NSRegularExpression

        init?(_ key: L10nKey) {
            let english = key.en
            guard !L10n.placeholders(english).isEmpty else { return nil }
            var pattern = "^"
            var literal = ""
            var it = english.makeIterator()
            func flush() {
                pattern += NSRegularExpression.escapedPattern(for: literal)
                literal = ""
            }
            while let c = it.next() {
                if c == "%", let p = it.next() {
                    if p == "d" { flush(); pattern += "([0-9]+)" } else if p == "@" || p == "T" { flush(); pattern += "(.+)" } else {
                        literal.append(c)
                        literal.append(p)
                    }
                } else {
                    literal.append(c)
                }
            }
            flush()
            pattern += "$"
            guard let r = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            self.key = key
            regex = r
        }

        func match(_ s: String) -> [String]? {
            let ns = s as NSString
            guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        }
    }

    private struct Index: Sendable {
        var exact: [String: L10nKey] = [:]
        var templates: [Template] = []
    }

    /// English → key (the first key wins; `L10nTests` checks that keys sharing an English text agree in Korean),
    /// and the templates, longest English first so a specific one wins over a general one.
    private static let index: Index = {
        var i = Index()
        for key in L10nKey.allCases {
            if let t = Template(key) {
                i.templates.append(t)
            } else if i.exact[key.en] == nil {
                i.exact[key.en] = key
            }
        }
        i.templates.sort { $0.key.en.count > $1.key.en.count }
        return i
    }()
}
