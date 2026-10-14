import AppKit
import DeskCore
import DeskScene

/// Keeps the scene's Reduce Motion flag current (DESIGN §2.1 juice kit, §4.8 `reduceMotion`, M10): on with
/// `--reduce-motion`, else as the `reduceMotion` setting says (follow the system's Accessibility ▸ Display ▸
/// Reduce motion, on, or off). The system option is watched through NSWorkspace's display-options notification;
/// a Settings change calls `refresh()`.
final class ReduceMotionObserver {
    private var token: (any NSObjectProtocol)?
    private let update: @MainActor () -> Void

    init(scene: DeskScene, forced: Bool, setting: @escaping () -> DeskSettings.ReduceMotion) {
        update = { [weak scene] in scene?.reduceMotion = Self.isOn(forced: forced, setting: setting()) }
        update()
        let update = update
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { update() }
        }
    }

    /// Re-reads the setting (Settings changed it).
    func refresh() {
        update()
    }

    /// Whether motion is reduced now.
    static func isOn(forced: Bool, setting: DeskSettings.ReduceMotion) -> Bool {
        if forced { return true }
        switch setting {
        case .on: return true
        case .off: return false
        case .followSystem: return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    func invalidate() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }
}
