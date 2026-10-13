import Foundation
import Testing

/// The scan of `scripts/check-file-safety.sh`, run in Swift (tests may not shell out). The patterns, allowlists
/// and `check` lines are read from the script itself, so the two cannot drift; the script's own self-test fixtures
/// are replayed too.
@Suite("File-safety lint")
struct FileSafetyLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let scriptURL = repo.appendingPathComponent("scripts/check-file-safety.sh")

    @Test("Sources, Tests and scripts pass the scan")
    func repoIsClean() throws {
        let lint = try Lint(script: String(contentsOf: Self.scriptURL, encoding: .utf8))
        let dirs = ["SRC": "Sources", "TESTS": "Tests", "SCRIPTS": "scripts"]
        var scanned = 0
        for (dirVar, dir) in dirs {
            let files = Self.files(under: Self.repo.appendingPathComponent(dir))
            scanned += files.count
            let found = lint.violations(dirVar: dirVar, files: files)
            #expect(found.isEmpty, "\(found.map(\.description).joined(separator: "\n"))")
        }
        #expect(scanned > 100)
        // Not vacuous: without the allowlists the file operator itself is flagged.
        let sources = Self.files(under: Self.repo.appendingPathComponent("Sources"))
        let strict = lint.violations(dirVar: "SRC", files: sources, ignoringAllowlists: true)
        #expect(strict.contains { $0.file == "DeskFiles/FileOperator.swift" && $0.label == "destructive" })
        #expect(strict.contains { $0.file == "DeskFiles/DesktopLocator.swift" && $0.label == "desktop-path" })
        #expect(strict.contains { $0.file == "DeskFiles/ExplicitIntent.swift" && $0.label == "intent-spi" })
        // Sources hold Swift only (the script's `check_foreign`).
        let foreign = Set(try #require(lint.vars["FOREIGN_EXTENSIONS"]).split(separator: " ").map(String.init))
        #expect(foreign.isSuperset(of: ["c", "m", "h", "modulemap"]))
        let e = FileManager.default.enumerator(at: Self.repo.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        let stray = (e?.allObjects ?? []).compactMap { $0 as? URL }.filter { foreign.contains($0.pathExtension) }
        #expect(stray.isEmpty, "\(stray.map(\.path))")
    }

    @Test("Every line of the script's Bypass fixtures is flagged and nothing in its clean fixtures")
    func selfTestFixtures() throws {
        let script = try String(contentsOf: Self.scriptURL, encoding: .utf8)
        let lint = try Lint(script: script)
        let fixtures = Self.heredocs(in: script)
        #expect(fixtures.count >= 5)
        for (path, text) in fixtures {
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            let dirVar = parts[0] == "Sources" ? "SRC" : "TESTS"
            let flagged = Set(lint.violations(dirVar: dirVar, files: [(parts[1], text)]).map(\.line))
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
            if path.hasSuffix("Bypass.swift") {
                #expect(flagged == Set(1...lines), "\(path): unflagged \(Set(1...lines).subtracting(flagged).sorted())")
            } else {
                #expect(flagged.isEmpty, "\(path): false positives on lines \(flagged.sorted())")
            }
        }
    }

    @Test("A planted violation is reported unless its file is allowlisted")
    func plantedViolation() throws {
        let lint = try Lint(script: String(contentsOf: Self.scriptURL, encoding: .utf8))
        let planted = """
            try FileManager.default.removeItem(at: url)
            let intent = ExplicitIntent(origin: .drop)
            _ = renamex_np(from, to, UInt32(RENAME_EXCL))
            // try FileManager.default.removeItem(at: url) in a comment is fine
            let pick = ExplicitIntent.Origin.drop
            @_spi(IntentMinting) import DeskFiles
            #expect(ExplicitIntent(origin: .drop) != nil)
            func removeAll(_ p: String) -> Int32 { remove(p) }
            """
        func lines(_ dirVar: String, _ file: String) -> [Int] {
            lint.violations(dirVar: dirVar, files: [(file, planted)]).map(\.line).uniqued()
        }
        #expect(lines("SRC", "DeskScene/Planted.swift") == [1, 2, 3, 6, 7, 8])
        #expect(lines("SRC", "DeskCore/Logic/Reducer.swift") == [1, 2, 3, 6, 7, 8])
        #expect(lines("SRC", "DeskFiles/FileOperator.swift") == [2, 6, 7])
        #expect(lines("SRC", "DeskteriorApp/Store/EffectRunner.swift") == [1, 3, 8])
        #expect(lines("SRC", "DeskteriorApp/EffectRunner.swift") == [1, 2, 3, 6, 7, 8])
        #expect(lines("TESTS", "DeskSceneTests/Planted.swift") == [2, 6, 7])
        #expect(lines("TESTS", "DeskFilesTests/Planted.swift") == [])
        // A shell script's `#` line is a comment.
        let quit = "kill" + "all" // spelled apart: Tests are scanned too
        let script = "# \(quit) Finder is never run\n\(quit) Dock\n"
        #expect(lint.violations(dirVar: "SCRIPTS", files: [("tool.sh", script)]).map(\.line) == [2])
    }

    // MARK: Files

    /// The `.swift` and `.sh` files under `dir`, as (path relative to `dir`, text).
    static func files(under dir: URL) -> [(String, String)] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [(String, String)] = []
        let base = dir.standardizedFileURL.path + "/"
        for case let url as URL in e {
            guard url.pathExtension == "swift" || url.pathExtension == "sh",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let path = url.standardizedFileURL.path
            out.append((path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path, text))
        }
        return out
    }

    /// `cat > "$tmp/<path>" <<'SWIFT'` … `SWIFT` blocks: path → text.
    static func heredocs(in script: String) -> [(String, String)] {
        var out: [(String, String)] = []
        var current: (String, [Substring])?
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            if var c = current {
                if line == "SWIFT" {
                    out.append((c.0, c.1.joined(separator: "\n") + "\n"))
                    current = nil
                } else {
                    c.1.append(line)
                    current = c
                }
            } else if let r = line.range(of: #"cat > "$tmp/"#), line.hasSuffix("<<'SWIFT'") {
                let rest = line[r.upperBound...]
                current = (String(rest.prefix { $0 != "\"" }), [])
            }
        }
        return out
    }
}

/// The checks of `check-file-safety.sh`: its pattern and allowlist variables, and its `check` lines.
struct Lint {
    struct Pattern {
        var source: String
        var regex: NSRegularExpression
        var exclude: NSRegularExpression?
    }

    struct Check {
        var label: String
        var dirVar: String
        var suffix: String
        var patterns: [Pattern]
        var allow: [String]
    }

    struct Violation: CustomStringConvertible {
        var label: String
        var file: String
        var line: Int
        var pattern: String
        var description: String { "[\(label)] /\(pattern)/ not allowed in \(file):\(line)" }
    }

    var checks: [Check] = []
    /// The script's variables, expanded.
    var vars: [String: String] = [:]
    /// Whole-line comments: `#` in shell scripts, `//` in Swift (where a line starting with `#` is code).
    static let shellComment = try! NSRegularExpression(pattern: #"^[[:space:]]*#"#)
    static let swiftComment = try! NSRegularExpression(pattern: #"^[[:space:]]*//"#)

    init(script: String) throws {
        let chars = Array(script)
        var vars: [String: String] = [:]
        var calls: [[String]] = []
        var i = 0
        while i < chars.count {
            // At the start of a line.
            var j = i
            while j < chars.count, chars[j].isLetter && chars[j].isUppercase || chars[j] == "_" || (j > i && chars[j].isNumber) {
                j += 1
            }
            if j > i, j < chars.count, chars[j] == "=", !String(chars[(j + 1)...].prefix(3)).hasPrefix("\"$(") {
                let name = String(chars[i..<j])
                var k = j + 1
                vars[name] = Self.word(chars, &k, vars)
                i = k
            } else if String(chars[i...].prefix(6)) == "check " {
                var k = i + 6
                var words: [String] = []
                var known = vars
                for d in ["SRC", "TESTS", "SCRIPTS"] { known[d] = d }
                while k < chars.count, chars[k] != "\n" {
                    if chars[k] == " " || chars[k] == "\t" { k += 1; continue }
                    words.append(Self.word(chars, &k, known))
                }
                calls.append(words)
                i = k
            }
            while i < chars.count, chars[i] != "\n" { i += 1 }
            i += 1
        }
        for words in calls {
            guard words.count == 5 else { throw LintError.badCheck(words.joined(separator: " ")) }
            let patterns = try words[3].split(separator: "\n").map { line -> Pattern in
                let parts = line.components(separatedBy: " !! ")
                // `^` and `$` match at line ends, so the whole-text pre-check below agrees with the per-line scan.
                return Pattern(
                    source: parts[0], regex: try NSRegularExpression(pattern: parts[0], options: [.anchorsMatchLines]),
                    exclude: try parts.count > 1 ? NSRegularExpression(pattern: parts[1]) : nil
                )
            }
            checks.append(Check(
                label: words[0], dirVar: words[1], suffix: String(words[2].drop { $0 == "*" }), patterns: patterns,
                allow: words[4].split(whereSeparator: \.isWhitespace).map(String.init)
            ))
        }
        guard checks.contains(where: { $0.dirVar == "SRC" }), checks.contains(where: { $0.dirVar == "TESTS" }) else {
            throw LintError.noChecks
        }
        self.vars = vars
    }

    enum LintError: Error {
        case badCheck(String)
        case noChecks
    }

    /// Like `grep -rnE` per pattern, then the script's filters: whole-line comments, `!!` excludes (the excluded
    /// text is removed and the rest of the line matched again), allowlists.
    func violations(dirVar: String, files: [(String, String)], ignoringAllowlists: Bool = false) -> [Violation] {
        var out: [Violation] = []
        for check in checks where check.dirVar == dirVar {
            let comment = check.suffix == ".sh" ? Self.shellComment : Self.swiftComment
            for (rel, text) in files where rel.hasSuffix(check.suffix) && !rel.hasSuffix("check-file-safety.sh") {
                if !ignoringAllowlists, Self.isAllowed(rel, check.allow) { continue }
                let whole = NSRange(text.startIndex..., in: text)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                for p in check.patterns {
                    // A per-line match is also a whole-text match, so this only skips files that cannot match.
                    guard p.regex.firstMatch(in: text, options: [], range: whole) != nil else { continue }
                    for (n, line) in lines.enumerated() {
                        let s = String(line)
                        let r = NSRange(s.startIndex..., in: s)
                        guard p.regex.firstMatch(in: s, options: [], range: r) != nil,
                              comment.firstMatch(in: s, options: [], range: r) == nil
                        else { continue }
                        if let exclude = p.exclude {
                            let rest = exclude.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: "")
                            let rr = NSRange(rest.startIndex..., in: rest)
                            guard p.regex.firstMatch(in: rest, options: [], range: rr) != nil else { continue }
                        }
                        out.append(Violation(label: check.label, file: rel, line: n + 1, pattern: p.source))
                    }
                }
            }
        }
        return out.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    /// An entry ending in "/" allows a whole directory.
    static func isAllowed(_ rel: String, _ allow: [String]) -> Bool {
        allow.contains { $0.hasSuffix("/") ? rel.hasPrefix($0) : rel == $0 }
    }

    /// One shell word from `i`: '…' literal, "…" with `$NAME`/`${NAME}` expanded and `\"`, `\\`, `\$` unescaped,
    /// bare text with `$NAME` expanded; adjacent parts concatenate. Stops at unquoted whitespace.
    static func word(_ c: [Character], _ i: inout Int, _ vars: [String: String]) -> String {
        var out = ""
        while i < c.count {
            switch c[i] {
            case "'":
                i += 1
                while i < c.count, c[i] != "'" { out.append(c[i]); i += 1 }
                i += 1
            case "\"":
                i += 1
                while i < c.count, c[i] != "\"" {
                    if c[i] == "\\", i + 1 < c.count, "\"\\$`".contains(c[i + 1]) {
                        out.append(c[i + 1])
                        i += 2
                    } else if c[i] == "$" {
                        out += expand(c, &i, vars)
                    } else {
                        out.append(c[i])
                        i += 1
                    }
                }
                i += 1
            case " ", "\t", "\n":
                return out
            case "$":
                out += expand(c, &i, vars)
            default:
                out.append(c[i])
                i += 1
            }
        }
        return out
    }

    /// `$NAME` or `${NAME}` at `i`; a lone `$` stays literal.
    static func expand(_ c: [Character], _ i: inout Int, _ vars: [String: String]) -> String {
        i += 1
        var name = ""
        if i < c.count, c[i] == "{" {
            i += 1
            while i < c.count, c[i] != "}" { name.append(c[i]); i += 1 }
            i += 1
        } else {
            while i < c.count, c[i].isASCII, c[i].isLetter || c[i].isNumber || c[i] == "_" { name.append(c[i]); i += 1 }
        }
        return name.isEmpty ? "$" : vars[name] ?? ""
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
