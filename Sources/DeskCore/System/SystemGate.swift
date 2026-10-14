/// What the system says about the desk right now (DESIGN §4.10–§5; M12): the app's `SystemObservers` turn
/// notifications into `SystemEvent`s, and `SystemGate` (pure) turns those into frame-loop holds, a frame-rate cap
/// and a few one-shot commands. Nothing here touches AppKit, so every rule is unit-tested.
public struct SystemConditions: Equatable, Sendable {
    /// The desk window is fully covered (no `.visible` occlusion state; SPIKES S3).
    public var occluded = false
    public var screensAsleep = false
    /// Fast user switching moved the session away.
    public var sessionInactive = false
    public var locked = false
    /// Pause Desk.
    public var userPaused = false
    public var onBattery = false
    public var lowPowerMode = false
    public var thermal = ThermalLevel.nominal
    /// Peek Desk is up: the user is looking at the desk on purpose.
    public var peeking = false
    /// The user is using the desk (a click, a key or a menu command, until a while after the last one).
    public var interacting = false

    public init() {}
}

/// `ProcessInfo.ThermalState`, as data.
public enum ThermalLevel: Int, Comparable, Sendable, CaseIterable {
    case nominal, fair, serious, critical

    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Why the frame loop must not run. The raw values are `FrameLoop`'s `PauseReason`s.
public enum LoopHold: String, Hashable, Sendable, CaseIterable {
    case occluded, screensAsleep, sessionInactive, locked, userPaused, onBattery
}

/// A system notification, as data.
public enum SystemEvent: Equatable, Sendable {
    case occlusion(visible: Bool)
    case screensSlept, screensWoke
    /// The Mac is about to sleep, and woke up.
    case willSleep, didWake
    case sessionResigned, sessionActivated
    case locked, unlocked
    case lowPowerMode(Bool)
    case thermal(ThermalLevel)
    case battery(onBattery: Bool)
    case userPaused(Bool)
    case peeking(Bool)
    /// The user started using the desk, or stopped a while ago.
    case interacting(Bool)
}

/// One-shot work an event asks for besides the holds.
public enum SystemCommand: Equatable, Sendable {
    /// Bring the scene to rest now (whatever is in the air lands, drawers commit) so nothing explodes on wake.
    case forceRest
    /// Save the layout now (DESIGN §4.8: on sleep and session resign).
    case flush
    /// Recompute every display's grid (wake, DESIGN §1.2).
    case refreshDisplays
    /// Rescan the mirrored folder (it may have changed while we slept or were switched away).
    case rescan
}

/// The frame-loop gating policy (DESIGN §5 pause sources): occlusion, display sleep, screen lock, fast user
/// switching and Pause Desk hold the loop; with the `pauseOnBattery` setting, so does running on battery (a frozen
/// frame), except while peeking or while the user is using the desk, so a click is never taken on a picture that does
/// not change. Low Power Mode or a thermal state of serious or worse caps the loop at 30 Hz. Clearing the last hold
/// resumes the loop (`FrameLoop` restarts its fixed-step clock, so a long pause never becomes one huge step).
public struct SystemGate: Equatable, Sendable {
    public private(set) var conditions: SystemConditions
    public var pauseOnBattery: Bool

    public init(conditions: SystemConditions = SystemConditions(), pauseOnBattery: Bool = false) {
        self.conditions = conditions
        self.pauseOnBattery = pauseOnBattery
    }

    /// The holds the loop should have now.
    public var holds: Set<LoopHold> {
        let c = conditions
        var out: Set<LoopHold> = []
        if c.occluded { out.insert(.occluded) }
        if c.screensAsleep { out.insert(.screensAsleep) }
        if c.sessionInactive { out.insert(.sessionInactive) }
        if c.locked { out.insert(.locked) }
        if c.userPaused { out.insert(.userPaused) }
        if pauseOnBattery, c.onBattery, !c.peeking, !c.interacting { out.insert(.onBattery) }
        return out
    }

    /// The highest frame rate the loop may ask for.
    public var maxFrameRate: Int {
        conditions.lowPowerMode || conditions.thermal >= .serious ? 30 : 60
    }

    /// True when the loop runs capped (`FrameLoop.lowPower`).
    public var capped: Bool { maxFrameRate < 60 }

    /// True while running on battery freezes the desk unless the user is using it (input should lift the hold).
    public var freezesOnBattery: Bool { pauseOnBattery && conditions.onBattery && !conditions.peeking }

    /// Applies an event; returns the one-shot commands it asks for.
    @discardableResult
    public mutating func handle(_ event: SystemEvent) -> [SystemCommand] {
        switch event {
        case let .occlusion(visible):
            conditions.occluded = !visible
        case .screensSlept:
            conditions.screensAsleep = true
            return [.forceRest]
        case .screensWoke:
            conditions.screensAsleep = false
        case .willSleep:
            return [.forceRest, .flush]
        case .didWake:
            return [.refreshDisplays, .rescan]
        case .sessionResigned:
            let first = !conditions.sessionInactive
            conditions.sessionInactive = true
            return first ? [.forceRest, .flush] : []
        case .sessionActivated:
            let was = conditions.sessionInactive
            conditions.sessionInactive = false
            return was ? [.refreshDisplays, .rescan] : []
        case .locked:
            conditions.locked = true
            return [.forceRest]
        case .unlocked:
            conditions.locked = false
        case let .lowPowerMode(on):
            conditions.lowPowerMode = on
        case let .thermal(level):
            conditions.thermal = level
        case let .battery(onBattery):
            conditions.onBattery = onBattery
        case let .userPaused(paused):
            conditions.userPaused = paused
            return paused ? [.forceRest, .flush] : []
        case let .peeking(on):
            conditions.peeking = on
        case let .interacting(on):
            conditions.interacting = on
        }
        return []
    }
}
