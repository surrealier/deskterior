import AppKit
import DeskCore
import DeskScene

/// Keeps the desk's interactive rects clear of desktop widgets (DESIGN §1.2 widget nudge; SPIKES S10). Widgets sit
/// one level above the desk and take its clicks, so their frames — read from the window list, which needs no Screen
/// Recording permission — become the scene's avoid rects and `LayoutSolver` nudges the core sideways until no critical
/// rect is under one. If no nudge clears them, a one-time tip toast says so. It probes at launch, when the screens
/// change, on wake and when another app activates (widget editing happens in Notification Center); never on a timer.
final class WidgetProbe {
    private weak var host: SceneHost?
    private weak var displays: DisplayManager?
    private var token: (any NSObjectProtocol)?
    private var tipShown = false
    private var lastRects: [ArtRect] = []

    init(host: SceneHost, displays: DisplayManager) {
        self.host = host
        self.displays = displays
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
    }

    func invalidate() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }

    /// Reads the widget frames and hands the desk's avoid rects to the scene.
    func probe() {
        guard let host, let desk = displays?.deskDisplay else { return }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .map(\.processIdentifier))
        guard !pids.isEmpty else { return apply([], host: host) }
        let primaryHeight = NSScreen.screens.first.map { Double($0.frame.height) } ?? desk.frame.height
        let widgets = WidgetGeometry.widgets(Self.windowList(), widgetPIDs: pids)
        let rects = WidgetGeometry.avoidRects(
            widgets, screenTopLeft: WidgetGeometry.topLeft(desk.frame, primaryHeight: primaryHeight), grid: host.grid
        )
        apply(rects, host: host)
    }

    private func apply(_ rects: [ArtRect], host: SceneHost) {
        guard rects != lastRects else { return }
        lastRects = rects
        host.scene.avoidRects = rects
        host.modelChanged()
        if !rects.isEmpty { Log.info("widgets: avoiding \(rects)") }
        if host.scene.layout?.avoidUnresolved == true, !tipShown {
            tipShown = true
            host.scene.toast(.widgetsOverlap)
            host.modelChanged()
        }
    }

    /// On-screen windows of every app, with owner PID, layer and bounds (global top-left points).
    static func windowList() -> [WidgetGeometry.Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { w in
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b) else { return nil }
            return WidgetGeometry.Window(pid: pid, layer: layer, bounds: PointRect(bounds))
        }
    }
}
