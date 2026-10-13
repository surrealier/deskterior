import Foundation

/// Finds bundled resources without SwiftPM resources (so no `Bundle.module`). Fonts are searched in order:
/// 1. `Bundle.main.resourceURL/Fonts` (the built .app);
/// 2. `$DESKTERIOR_RESOURCES/Fonts`;
/// 3. the repo's `Resources/Fonts`, located from this source file (`swift run`, tests).
public enum ResourceLocator {
    public static let resourcesEnvironmentKey = "DESKTERIOR_RESOURCES"

    /// Candidate font directories in search order (existing or not).
    public static func fontDirectoryCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var out: [URL] = []
        if let res = Bundle.main.resourceURL {
            out.append(res.appendingPathComponent("Fonts", isDirectory: true))
        }
        if let env = environment[resourcesEnvironmentKey], !env.isEmpty {
            out.append(URL(fileURLWithPath: env, isDirectory: true).appendingPathComponent("Fonts", isDirectory: true))
        }
        out.append(repoFontsDirectory)
        return out
    }

    /// The first existing font directory, or nil.
    public static func fontsDirectory() -> URL? {
        fontDirectoryCandidates().first(where: isDirectory)
    }

    /// The first candidate directory's file called `name` (e.g. "Galmuri9.ttf") that exists, or nil.
    public static func fontURL(named name: String) -> URL? {
        for dir in fontDirectoryCandidates() {
            let url = dir.appendingPathComponent(name, isDirectory: false)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                return url
            }
        }
        return nil
    }

    /// `<repo>/Resources/Fonts`, from this file's path (`Sources/DeskPixels/ResourceLocator.swift`).
    static let repoFontsDirectory: URL = URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent()          // Sources/DeskPixels
        .deletingLastPathComponent()          // Sources
        .deletingLastPathComponent()          // repo root
        .appendingPathComponent("Resources", isDirectory: true)
        .appendingPathComponent("Fonts", isDirectory: true)
        .standardizedFileURL

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
