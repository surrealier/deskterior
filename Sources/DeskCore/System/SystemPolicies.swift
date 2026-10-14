import Foundation

// The opt-in system hooks (DESIGN §2.2 E16, §4.8, §6; M12) as policies over small protocols, so tests drive them
// with fakes and the app plugs in Carbon's `RegisterEventHotKey` and `SMAppService.mainApp`. Both are OFF by
// default and are only ever registered from a setting the user turned on.

// MARK: - Global hotkey

/// A global key combination, Carbon style (virtual key code and modifier bits).
public struct HotKeyBinding: Equatable, Sendable {
    public var keyCode: UInt32
    /// `cmdKey | optionKey | controlKey | shiftKey` bits (Carbon `Events.h`).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Carbon modifier bits (`Events.h`): cmdKey 1 << 8, shiftKey 1 << 9, optionKey 1 << 11, controlKey 1 << 12.
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    /// ⌃⌥⌘D (`kVK_ANSI_D` = 2): Peek Desk.
    public static let peekDesk = HotKeyBinding(keyCode: 2, modifiers: control | option | command)
}

/// Registers one global hotkey (the app: Carbon `RegisterEventHotKey`, no Accessibility permission).
public protocol HotKeyRegistrar: AnyObject {
    /// True when the key is now registered.
    func registerHotKey(_ binding: HotKeyBinding) -> Bool
    func unregisterHotKey()
}

/// Keeps the Peek hotkey registered exactly while its setting is on.
public struct HotKeyPolicy: Equatable, Sendable {
    public private(set) var registered = false
    public let binding: HotKeyBinding

    public init(binding: HotKeyBinding = .peekDesk) {
        self.binding = binding
    }

    /// Registers or unregisters to match `enabled`; nothing happens when they already match. Returns whether the
    /// key is registered afterwards.
    @discardableResult
    public mutating func apply(enabled: Bool, with registrar: some HotKeyRegistrar) -> Bool {
        if enabled, !registered {
            registered = registrar.registerHotKey(binding)
        } else if !enabled, registered {
            registrar.unregisterHotKey()
            registered = false
        }
        return registered
    }
}

// MARK: - Launch at Login

/// `SMAppService.Status`, as data.
public enum LoginItemStatus: String, Equatable, Sendable {
    case notRegistered, enabled, requiresApproval, notFound
}

/// The login item service (the app: `SMAppService.mainApp`, called off the main thread).
public protocol LoginItemService: AnyObject, Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// What a launch-at-login change or launch check did, for the Settings window's status line.
public enum LoginItemOutcome: Equatable, Sendable {
    /// Nothing to do (off and never registered by us, or on and current).
    case unchanged
    case added
    /// Registered, but the user must approve it in System Settings ▸ General ▸ Login Items.
    case needsApproval
    case removed
    case failed
    /// It was turned off outside the app (System Settings): the setting follows.
    case turnedOffElsewhere
}

/// Launch at Login (DESIGN §4.8, §9): off by default; only the Settings toggle registers; status is read off the
/// main thread (by the caller). After an update the item is registered again (ad-hoc signed builds otherwise keep a
/// stale item), but only if the user had opted in. `settings.loginItemVersion` remembers which version registered it.
public enum LoginItemPolicy {
    /// At launch: with the setting off, the service is never touched. With it on: register again when the version
    /// changed; follow a removal made in System Settings (the setting turns off).
    public static func launch(_ settings: inout DeskSettings, version: String, service: some LoginItemService)
        -> LoginItemOutcome {
        guard settings.launchAtLogin else { return .unchanged }
        let status = service.status
        if settings.loginItemVersion == version {
            switch status {
            case .enabled: return .unchanged
            case .requiresApproval: return .needsApproval
            case .notRegistered, .notFound:
                settings.launchAtLogin = false
                settings.loginItemVersion = nil
                return .turnedOffElsewhere
            }
        }
        return register(&settings, version: version, service: service)
    }

    /// The Settings toggle.
    public static func set(_ on: Bool, _ settings: inout DeskSettings, version: String, service: some LoginItemService)
        -> LoginItemOutcome {
        if on {
            settings.launchAtLogin = true
            return register(&settings, version: version, service: service)
        }
        settings.launchAtLogin = false
        settings.loginItemVersion = nil
        guard service.status == .enabled || service.status == .requiresApproval else { return .removed }
        do {
            try service.unregister()
            return .removed
        } catch {
            return .failed
        }
    }

    private static func register(_ settings: inout DeskSettings, version: String, service: some LoginItemService)
        -> LoginItemOutcome {
        do {
            try service.register()
        } catch {
            // Already registered is fine; anything else leaves the setting on but reports the failure.
            if service.status != .enabled && service.status != .requiresApproval { return .failed }
        }
        settings.loginItemVersion = version
        return service.status == .requiresApproval ? .needsApproval : .added
    }
}

// MARK: - App Translocation

/// App Translocation (DESIGN §6): a quarantined app opened from where it was unzipped runs from a randomized
/// read-only path; it should be moved to /Applications first.
public enum Translocation {
    public static func isTranslocated(bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// Show the one-time note now?
    public static func shouldShowNote(bundlePath: String, settings: DeskSettings) -> Bool {
        isTranslocated(bundlePath: bundlePath) && !settings.translocationNoteShown
    }
}

// MARK: - Widgets

/// Desktop widgets sit one level above the desk (SPIKES S10): `WidgetProbe` reads their frames from the window list
/// (no Screen Recording needed) and the layout keeps critical rects clear of them (`LayoutSolver` nudge).
public enum WidgetGeometry {
    /// One window-list entry: owner PID, window layer and bounds in global top-left points (`kCGWindowBounds`).
    public struct Window: Equatable, Sendable {
        public var pid: Int32
        public var layer: Int
        public var bounds: PointRect

        public init(pid: Int32, layer: Int, bounds: PointRect) {
            self.pid = pid
            self.layer = layer
            self.bounds = bounds
        }
    }

    /// The widget windows: owned by the widget host (`widgetPIDs`, the processes of bundle
    /// `com.apple.notificationcenterui`, matched by PID because its name is localized), below normal windows
    /// (banners and Notification Center itself sit far above), and of a widget's size.
    public static func widgets(_ windows: [Window], widgetPIDs: Set<Int32>) -> [PointRect] {
        windows.filter { w in
            widgetPIDs.contains(w.pid) && w.layer < 0 && w.bounds.width >= 40 && w.bounds.height >= 40
        }.map(\.bounds)
    }

    /// Canvas art rects (rounded outward) of widget `rects` that meet the display whose frame in global top-left
    /// points is `screenTopLeft`, for `grid`.
    public static func avoidRects(_ rects: [PointRect], screenTopLeft: PointRect, grid: PixelGrid) -> [ArtRect] {
        rects.compactMap { r in
            let local = r.intersection(screenTopLeft)
            guard !local.isEmpty else { return nil }
            let x0 = local.minX - screenTopLeft.minX, y0 = local.minY - screenTopLeft.minY
            let a = grid.artPoint(fromViewPoint: SIMD2(x0, y0))
            // The last art pixel the widget touches (half-open: back off an epsilon from the far edge).
            let b = grid.artPoint(fromViewPoint: SIMD2(x0 + local.width - 0.001, y0 + local.height - 0.001))
            return ArtRect(a.x, a.y, b.x - a.x + 1, b.y - a.y + 1)
        }
    }

    /// A display's frame (AppKit global, y-up from the bottom of the menu-bar display of height `primaryHeight`) in
    /// the window list's top-left coordinates.
    public static func topLeft(_ frame: PointRect, primaryHeight: Double) -> PointRect {
        PointRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
