import AppKit
// quitapp NAME: asks every running app with that localized name to quit (like Quit from its menu).
let name = CommandLine.arguments[1]
for app in NSWorkspace.shared.runningApplications where app.localizedName == name {
    print("quit \(app.processIdentifier) \(app.bundleIdentifier ?? "") -> \(app.terminate())")
}
