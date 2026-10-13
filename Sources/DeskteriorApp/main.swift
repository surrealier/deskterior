import AppKit
import DeskCore

func launchOptions() -> LaunchOptions {
    do {
        let arguments = Array(CommandLine.arguments.dropFirst())
        return try LaunchOptions.parse(arguments, environment: ProcessInfo.processInfo.environment)
    } catch {
        FileHandle.standardError.write(Data("Deskterior: \(error)\n\n\(LaunchOptions.usage)\n".utf8))
        exit(2)
    }
}

let options = launchOptions()
if options.showHelp {
    print(LaunchOptions.usage)
    exit(0)
}
if options.showVersion {
    print("Deskterior \(DeskCore.version)")
    exit(0)
}
if options.mode == .headless {
    exit(AppDelegate.runHeadless(options))
}
if options.mode == .desk, AppIdentity.anotherInstanceIsRunning() {
    print("Deskterior is already running.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
// No Dock icon and no menu bar (DESIGN Errata 1); needed explicitly under `swift run` (no Info.plist).
app.setActivationPolicy(.accessory)
app.run()
