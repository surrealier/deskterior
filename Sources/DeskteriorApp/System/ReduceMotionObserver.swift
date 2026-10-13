import AppKit
import DeskCore
import DeskScene

/// Keeps the scene's Reduce Motion flag current (DESIGN §2.1 juice kit, §4.8 `reduceMotion`, M10): on with
/// `--reduce-motion`, else as the `reduceMotion` setting says (follow the system's Accessibility ▸ Display ▸
/// Reduce motion, on, or off). The system option is watched through NSWorkspace's display-options notification.
final class ReduceMotionObserver {
    private var token: (any NSObjectProtocol)?

    init(scene: DeskScene, forced: Bool) {
        let update: @MainActor () -> Void = { [weak scene] in scene?.reduceMotion = Self.isOn(forced: forced) }
        update()
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { update() }
        }
    }

    /// Whether motion is reduced now.
    static func isOn(forced: Bool) -> Bool {
        if forced { return true }
        let defaults = UserDefaults(suiteName: AppIdentity.bundleID)
        switch DeskSettings(reading: { defaults?.object(forKey: $0) }).reduceMotion {
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
