import AppKit
import DeskCore
import DeskScene
import IOKit.ps

/// Turns system notifications into `SystemEvent`s for the pure `SystemGate` (DESIGN §5, §4.10; M12): occlusion of
/// the desk window, display sleep and wake, system sleep and wake, fast user switching, screen lock, Low Power Mode,
/// the thermal state and the power source. After each event it applies the gate to the desk's `FrameLoop` (pause
/// reasons and the 30 Hz cap) and hands the event's commands (settle, save, regrid, rescan) to `onCommand`.
final class SystemObservers {
    private(set) var gate: SystemGate
    weak var loop: FrameLoop?
    /// One-shot work an event asks for.
    var onCommand: ((SystemCommand) -> Void)?
    private var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var occlusionToken: (any NSObjectProtocol)?
    private var powerSource: CFRunLoopSource?

    init(loop: FrameLoop, pauseOnBattery: Bool) {
        self.loop = loop
        gate = SystemGate(pauseOnBattery: pauseOnBattery)
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.send(.screensSlept) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.send(.screensWoke) }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.send(.willSleep) }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.send(.didWake) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.send(.sessionResigned) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.send(.sessionActivated) }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.send(.locked) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.send(.unlocked) }
        observe(.default, Notification.Name.NSProcessInfoPowerStateDidChange) { [weak self] in
            self?.send(.lowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled))
        }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in
            self?.send(.thermal(Self.thermalLevel()))
        }
        gate.handle(.lowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled))
        gate.handle(.thermal(Self.thermalLevel()))
        gate.handle(.battery(onBattery: Self.onBattery()))
        startPowerSourceNotifications()
        applyGate()
    }

    /// Follows the occlusion state of the desk window (again after the desk moves to another display).
    func watchOcclusion(of window: NSWindow) {
        if let occlusionToken { NotificationCenter.default.removeObserver(occlusionToken) }
        occlusionToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                let visible = window.occlusionState.contains(.visible)
                if visible == self.gate.conditions.occluded { Log.info(visible ? "visible" : "occluded") }
                self.send(.occlusion(visible: visible))
            }
        }
    }

    /// Feeds an event (also the app's own: Pause Desk, Peek Desk) and applies the result.
    func send(_ event: SystemEvent) {
        let commands = gate.handle(event)
        applyGate()
        for c in commands { onCommand?(c) }
    }

    /// The "pause on battery" setting changed.
    func setPauseOnBattery(_ on: Bool) {
        gate.pauseOnBattery = on
        applyGate()
    }

    private func applyGate() {
        guard let loop else { return }
        let holds = gate.holds
        for hold in LoopHold.allCases {
            guard let reason = PauseReason(rawValue: hold.rawValue) else { continue }
            let on = holds.contains(hold)
            if loop.pauseReasons.contains(reason) != on { loop.setPaused(reason, on) }
        }
        if loop.lowPower != gate.capped { loop.lowPower = gate.capped }
    }

    func invalidate() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        if let occlusionToken { NotificationCenter.default.removeObserver(occlusionToken) }
        occlusionToken = nil
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerSource = nil
    }

    // MARK: Sources

    static func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }

    /// True while the Mac draws from its battery.
    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    /// IOKit calls back on the main run loop whenever a power source changes.
    private func startPowerSourceNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<SystemObservers>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                let now = SystemObservers.onBattery()
                if now != me.gate.conditions.onBattery { me.send(.battery(onBattery: now)) }
            }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        tokens.append((center, token))
    }
}
