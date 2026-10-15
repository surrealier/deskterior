import AppKit
// actpol NAME [activate]: prints the app's activation policy / active / hidden; with "activate" activates it.
for a in NSWorkspace.shared.runningApplications where a.localizedName == CommandLine.arguments[1] {
    if CommandLine.arguments.count > 2 { print("activate ->", a.activate(options: [])) ; usleep(300_000) }
    print(a.localizedName ?? "", a.activationPolicy.rawValue, "active", a.isActive, "hidden", a.isHidden)
}
