import Foundation
import os

/// Finds bundled resources without SwiftPM resources (so no `Bundle.module`). Fonts are searched in order:
/// 1. `Bundle.main.resourceURL/Fonts` (the built .app);
/// 2. `$DESKTERIOR_RESOURCES/Fonts`;
/// 3. debug builds only: the repo's `Resources/Fonts`, located from this source file (`swift run`, tests).
///    Release binaries carry no source paths.
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
        if let repoFontsDirectory { out.append(repoFontsDirectory) }
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

    /// True when running from a built `.app` bundle, whose `Contents/Resources` must hold every resource.
    public static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Reports a resource that could not be found or loaded: a fault in the unified log, and in a debug
    /// build of the app bundle an assertion failure (a packaging bug). Outside a bundle (tests, `swift run`)
    /// it only logs.
    public static func reportMissing(_ name: String) {
        logger.fault("Missing or unreadable resource \(name, privacy: .public)")
        if isAppBundle {
            assertionFailure("\(name) is missing from the app bundle's Resources")
        }
    }

    #if DEBUG
    /// `<repo>/Resources/Fonts`, from this file's path (`Sources/DeskPixels/ResourceLocator.swift`).
    static let repoFontsDirectory: URL? = URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent()          // Sources/DeskPixels
        .deletingLastPathComponent()          // Sources
        .deletingLastPathComponent()          // repo root
        .appendingPathComponent("Resources", isDirectory: true)
        .appendingPathComponent("Fonts", isDirectory: true)
        .standardizedFileURL
    #else
    static let repoFontsDirectory: URL? = nil
    #endif

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "deskterior", category: "resources")

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
