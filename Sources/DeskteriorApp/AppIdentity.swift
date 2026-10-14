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
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            return isDuplicate(me: me, bundleID: id, executable: nil,
                               running: others.map { RunningApp(pid: $0.processIdentifier, bundleID: id, executable: nil) })
        }
        let running = NSWorkspace.shared.runningApplications.map {
            RunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, executable: $0.executableURL)
        }
        return isDuplicate(me: me, bundleID: nil, executable: Bundle.main.executableURL, running: running)
    }

    // MARK: harden

    /// One running process, as the single-instance guard sees it.
    struct RunningApp: Equatable {
        var pid: Int32
        var bundleID: String?
        var executable: URL?
    }

    /// The single-instance decision (pure): another process than `me` runs our bundle id, or (unbundled, no id) the
    /// same executable file, symlinks resolved. A process that cannot be named is never taken for us.
    static func isDuplicate(me: Int32, bundleID: String?, executable: URL?, running: [RunningApp]) -> Bool {
        let others = running.filter { $0.pid != me }
        if let bundleID { return others.contains { $0.bundleID == bundleID } }
        guard let exe = executable?.resolvingSymlinksInPath() else { return false }
        return others.contains { $0.executable?.resolvingSymlinksInPath() == exe }
    }

    /// Only desk mode refuses to start twice; development runs (windowed, headless, demos) may run beside the desk.
    static func checksForDuplicates(_ options: LaunchOptions) -> Bool { options.mode == .desk }
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
