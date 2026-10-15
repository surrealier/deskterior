import AppKit
for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
    print(a.localizedName ?? "?", a.bundleIdentifier ?? "", "hidden:", a.isHidden, "active:", a.isActive)
}
