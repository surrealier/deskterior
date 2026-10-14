import AppKit
import DeskCore
import os

/// Who this process is: the bundle id (with a fallback under `swift run`, where there is no Info.plist), where its
/// settings live, and whether another desk instance is already running.
enum AppIdentity {
    static let fallbackBundleID = "io.github.deskterior.dev"

    static var bundleID: String { Bundle.main.bundleIdentifier ?? fallbackBundleID }

    /// The settings' defaults (DESIGN §4.8): the app's own domain inside the .app, the fallback id's suite when
    /// unbundled (`DeskSettings.suiteName`). Only `SettingsStore` reads or writes it, and only in desk mode.
    static var defaults: UserDefaults {
        DeskSettings.suiteName(bundleIdentifier: Bundle.main.bundleIdentifier, fallback: fallbackBundleID)
            .flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// True when another Deskterior with our bundle id (or, unbundled, our executable) is running.
    static func anotherInstanceIsRunning() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .contains { $0.processIdentifier != me }
        }
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return false }
        return NSWorkspace.shared.runningApplications.contains {
            $0.processIdentifier != me && $0.executableURL?.resolvingSymlinksInPath() == exe
        }
    }
}

/// Development log: unified logging (`log stream --predicate 'subsystem == "<bundle id>"'`), echoed to stderr
/// when it is a terminal.
enum Log {
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "app")
    private static let echo = isatty(STDERR_FILENO) != 0

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        if echo { FileHandle.standardError.write(Data(("Deskterior: " + message + "\n").utf8)) }
    }
}
