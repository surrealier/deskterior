import AppKit

/// The desk window (DESIGN §4.5): borderless and *activating* (like Finder's desktop), one level above the
/// desktop icons, on every Space, never moved, hidden, restored or cycled. Shown with `orderFrontRegardless()`;
/// never made key at launch.
final class DeskWindow: NSWindow {
    init(frame: NSRect, level choice: LaunchOptions.Level) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = Self.windowLevel(choice)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        hidesOnDeactivate = false
        canHide = false
        isMovable = false
        isRestorable = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func windowLevel(_ choice: LaunchOptions.Level) -> NSWindow.Level {
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        switch choice {
        case .iconPlus1: return NSWindow.Level(rawValue: icons + 1)
        case .iconPlus3: return NSWindow.Level(rawValue: icons + 3)
        case .normal: return .normal
        }
    }
}

/// The `--windowed` development window: a normal titled, resizable window whose content view emulates a
/// display of its size. The frame is never constrained to the screen, so a full-size emulation may run past
/// the bottom edge instead of shrinking.
final class WindowedDeskWindow: NSWindow {
    init(contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        title = "Deskterior"
        isRestorable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        backgroundColor = .black
        contentMinSize = NSSize(width: 320, height: 200)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
