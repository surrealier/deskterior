import AppKit
import DeskScene

/// Turns system state into `FrameLoop` pause reasons (DESIGN §5): window occlusion, display sleep, fast user
/// switching and screen lock pause the loop; clearing the last reason renders one frame. Low Power Mode caps
/// the loop at 30 Hz; a system wake re-checks the display grid.
final class SystemObservers {
    private var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    init(window: NSWindow, loop: FrameLoop, onSystemWake: @escaping @MainActor () -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        observe(.default, NSWindow.didChangeOcclusionStateNotification, object: window) { [weak window, weak loop] in
            guard let window, let loop else { return }
            let hidden = !window.occlusionState.contains(.visible)
            if hidden != loop.pauseReasons.contains(.occluded) { Log.info(hidden ? "occluded" : "visible") }
            loop.setPaused(.occluded, hidden)
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak loop] in
            loop?.setPaused(.screensAsleep, true)
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak loop] in
            loop?.setPaused(.screensAsleep, false)
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak loop] in
            loop?.setPaused(.sessionInactive, true)
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak loop] in
            loop?.setPaused(.sessionInactive, false)
        }
        observe(workspace, NSWorkspace.didWakeNotification) {
            onSystemWake()
        }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak loop] in
            loop?.setPaused(.locked, true)
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak loop] in
            loop?.setPaused(.locked, false)
        }
        observe(.default, Notification.Name.NSProcessInfoPowerStateDidChange) { [weak loop] in
            loop?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        loop.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func invalidate() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
        _ handler: @escaping @MainActor () -> Void
    ) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        tokens.append((center, token))
    }
}
