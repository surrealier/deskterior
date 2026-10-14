/// What the powered screen shows over its wallpaper (DESIGN §2.2 E1–E2, §3.1 item 2).
public enum ScreenOverlay: String, Sendable, CaseIterable {
    /// The desktop: tokens on the current HDMI page.
    case none
    /// First run: "PRESS ⏻ TO CONNECT DESKTOP"; the power button runs the first enumeration.
    case connectPrompt
    /// The first enumeration is running and no layout is known yet.
    case connecting
    /// The folder could not be read: NO SIGNAL card with Open Settings and Choose Folder….
    case noAccess
    /// Finder hides desktop items: the DESKTOP HIDDEN card (Show / Keep hidden).
    case desktopHidden
    /// The AV input: always empty, a bouncing NO SIGNAL logo.
    case av

    public static func of(_ s: DeskState) -> ScreenOverlay {
        switch s.access {
        case .notConnected: .connectPrompt
        case .finderHidden: .desktopHidden
        case .denied: .noAccess
        case .connecting where s.tokens.isEmpty: .connecting
        case .connecting, .connected: s.monitor.av ? .av : .none
        }
    }
}

/// The NO SIGNAL logo of the AV input: it steps diagonally at 8 fps and bounces off the screen edges for at most
/// `MonitorMachine.avBounceLimit` seconds after the input switches (or the screen is hovered), then holds still.
/// A bounce off two edges at once (a corner) sparkles.
public struct BouncingLogo: Sendable, Equatable {
    /// Top-left inside the screen (screen px).
    public private(set) var position: ArtPoint
    public let size: ArtSize
    public let bounds: ArtSize
    private var velocity = ArtPoint(2, 1)
    private var clock: Double = 0
    /// Seconds of bouncing left.
    public private(set) var remaining: Double = 0
    /// Seconds of sparkle left after a corner hit.
    public private(set) var sparkle: Double = 0
    /// Corner hits so far.
    public private(set) var cornerHits = 0

    public static let sparkleDuration = 0.5

    public init(size: ArtSize, bounds: ArtSize) {
        self.size = size
        self.bounds = bounds
        position = ArtPoint((bounds.w - size.w) / 2, (bounds.h - size.h) / 2)
    }

    public var isMoving: Bool { remaining > 0 }

    /// Bounces for another `seconds`.
    public mutating func wake(for seconds: Double) {
        remaining = max(remaining, seconds)
    }

    /// Stops at once (hard sleep).
    public mutating func freeze() {
        remaining = 0
        sparkle = 0
    }

    public mutating func step(_ dt: Double) {
        sparkle = max(0, sparkle - dt)
        guard remaining > 0 else { return }
        remaining = max(0, remaining - dt)
        clock += dt
        while clock >= MonitorMachine.avFrameTime {
            clock -= MonitorMachine.avFrameTime
            move()
        }
    }

    // MARK: harden
    /// The corner sparkle's frame (0, 1, 2, 0 …, every 1/12 s from the hit), nil when none shows.
    public var sparkleFrame: Int? {
        sparkle > 0 ? Int((Self.sparkleDuration - sparkle) * 12) % 3 : nil
    }

    /// How many `dt` steps from now its picture next changes: its next move, its sparkle's next frame or the
    /// sparkle's end, nil when neither runs. Counted with `step`'s own arithmetic, so a tick of exactly that many
    /// steps shows exactly one change (Errata 25).
    public func stepsToNextChange(dt: Double) -> Int? {
        guard dt > 0, isMoving || sparkle > 0 else { return nil }
        var probe = self
        let start = (probe.position, probe.sparkleFrame)
        for n in 1...Int((MonitorMachine.avFrameTime / dt).rounded(.up)) + 1 {
            probe.step(dt)
            if probe.position != start.0 || probe.sparkleFrame != start.1 || !(probe.isMoving || probe.sparkle > 0) {
                return n
            }
        }
        return nil
    }

    private mutating func move() {
        let maxX = max(0, bounds.w - size.w), maxY = max(0, bounds.h - size.h)
        var p = position + velocity
        var hits = 0
        if p.x <= 0 || p.x >= maxX {
            p.x = min(max(p.x, 0), maxX)
            velocity.x = -velocity.x
            hits += 1
        }
        if p.y <= 0 || p.y >= maxY {
            p.y = min(max(p.y, 0), maxY)
            velocity.y = -velocity.y
            hits += 1
        }
        if hits == 2 {
            cornerHits += 1
            sparkle = Self.sparkleDuration
        }
        position = p
    }
}

/// The monitor's visible state over time (DESIGN §2.2 E1–E2): power phases with the CRT collapse and bloom, the
/// row-by-row pop-in, static and the input OSD after a page change, the amber LED (three blinks, then a steady
/// pip) and "+N" badge for files that arrive while it is off, and the AV logo. Pure and frame-stepped; the scene
/// feeds it the model with `sync` and renders what it reports. Every animation is bounded (CRT ≤ 0.7 s, AV logo
/// ≤ 10 s), so the frame loop can always come to rest.
public struct MonitorMachine: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case on, poweringOff, off, poweringOn
    }

    /// Which CRT frame covers the screen.
    public enum CRTFrame: Sendable, Equatable {
        /// `MonitorArt.powerOffFrames` index.
        case off(Int)
        /// `MonitorArt.powerOnFrames` index.
        case on(Int)
    }

    public static let crtFrameTime = 1.0 / 12
    public static let powerOffFrameCount = 6
    public static let powerOnFrameCount = 8
    /// Icons pop in one screen row at a time after the bloom.
    public static let rowStagger = 2.0 / 30
    public static let rows = CoreLayout.screenRows
    public static let staticFrameCount = 2
    public static let osdDuration = 1.0
    public static let avFrameTime = 1.0 / 8
    public static let avBounceLimit = 10.0
    public static let ledBlinks = 3
    /// One amber-on plus one off.
    public static let ledBlinkPeriod = 0.4

    public static var powerOffDuration: Double { Double(powerOffFrameCount) * crtFrameTime }
    public static var bloomDuration: Double { Double(powerOnFrameCount) * crtFrameTime }
    public static var powerOnDuration: Double { bloomDuration + Double(rows) * rowStagger }

    public private(set) var phase: Phase
    /// Seconds since the phase began.
    public private(set) var phaseTime: Double = 0
    public private(set) var overlay: ScreenOverlay
    public private(set) var pendingNew: Int
    public private(set) var logo: BouncingLogo
    private var staticLeft: Double = 0
    private var osdLeft: Double = 0
    public private(set) var osdText: String?
    private var ledBlinkTime: Double?
    private var page: Int
    private var av: Bool
    // MARK: harden
    /// Reduce Motion: the AV logo holds still where it is (no bounce, no sparkle).
    public private(set) var logoStill = false

    /// At rest in `s` (no animation for the state the desk starts in).
    public init(_ s: DeskState, logoSize: ArtSize = MonitorArt.noSignalLogo().size, screen: ArtSize = CoreLayout.screen.size) {
        phase = s.monitor.power == .on ? .on : .off
        overlay = ScreenOverlay.of(s)
        pendingNew = s.monitor.pendingNew
        page = s.monitor.page
        av = s.monitor.av
        logo = BouncingLogo(size: logoSize, bounds: screen)
        if overlay == .av, phase == .on { logo.wake(for: Self.avBounceLimit) }
    }

    /// Adopts a new model state and starts the transitions it implies.
    public mutating func sync(_ s: DeskState) {
        let powered = s.monitor.power == .on
        switch (phase, powered) {
        case (.on, false), (.poweringOn, false):
            phase = .poweringOff
            phaseTime = 0
            staticLeft = 0
            osdLeft = 0
            osdText = nil
        case (.off, true), (.poweringOff, true):
            phase = .poweringOn
            phaseTime = 0
        default:
            break
        }
        let newOverlay = ScreenOverlay.of(s)
        let inputChanged = s.monitor.page != page || s.monitor.av != av
        if inputChanged, powered, phase == .on {
            staticLeft = Double(Self.staticFrameCount) * Self.crtFrameTime
            osdText = Self.osdText(s)
            osdLeft = Self.osdDuration
        }
        if newOverlay == .av, overlay != .av || inputChanged || phase == .poweringOn, !logoStill {
            logo.wake(for: Self.avBounceLimit)
        }
        if s.monitor.pendingNew > pendingNew, !powered { ledBlinkTime = 0 }
        if s.monitor.pendingNew == 0 { ledBlinkTime = nil }
        overlay = newOverlay
        pendingNew = s.monitor.pendingNew
        page = s.monitor.page
        av = s.monitor.av
    }

    /// Hovering the AV screen restarts the logo's bounce.
    public mutating func wakeLogo() {
        guard overlay == .av, phase == .on, !logoStill else { return }
        logo.wake(for: Self.avBounceLimit)
    }

    // MARK: harden
    /// Reduce Motion on: the AV logo stops where it is and stays still (Errata 25); off: it bounces when next woken.
    public mutating func holdLogoStill(_ still: Bool) {
        logoStill = still
        if still { logo.freeze() }
    }

    public mutating func step(_ dt: Double) {
        phaseTime += dt
        switch phase {
        case .poweringOff where phaseTime >= Self.powerOffDuration:
            phase = .off
            phaseTime = 0
        case .poweringOn where phaseTime >= Self.powerOnDuration:
            phase = .on
            phaseTime = 0
        default:
            break
        }
        staticLeft = max(0, staticLeft - dt)
        if osdLeft > 0 {
            osdLeft -= dt
            if osdLeft <= 0 {
                osdLeft = 0
                osdText = nil
            }
        }
        if let t = ledBlinkTime {
            let next = t + dt
            ledBlinkTime = next >= Double(Self.ledBlinks) * Self.ledBlinkPeriod ? nil : next
        }
        if overlay == .av, phase == .on { logo.step(dt) }
    }

    /// Hard sleep: ends every animation at its final frame.
    public mutating func settle() {
        if phase == .poweringOff { phase = .off }
        if phase == .poweringOn { phase = .on }
        phaseTime = 0
        staticLeft = 0
        osdLeft = 0
        osdText = nil
        ledBlinkTime = nil
        logo.freeze()
    }

    /// True while anything on the monitor animates.
    public var needsFrames: Bool {
        phase == .poweringOff || phase == .poweringOn || staticLeft > 0 || osdLeft > 0 || ledBlinkTime != nil
            || (overlay == .av && phase == .on && (logo.isMoving || logo.sparkle > 0))
    }

    // MARK: harden
    /// While the AV logo is all that animates here: the time until its picture next changes (its next 8 fps move,
    /// or the corner sparkle's next 12 fps frame), a whole number of fixed `step`s, so the frame loop can tick just
    /// then instead of at 60 Hz and show every change once (Errata 25); else nil.
    public func logoFrameInterval(step: Double = 1.0 / 60) -> Double? {
        guard needsFrames, phase == .on, overlay == .av, staticLeft == 0, osdLeft == 0, ledBlinkTime == nil,
              let n = logo.stepsToNextChange(dt: step) else {
            return nil
        }
        return Double(n) * step
    }

    // MARK: What to draw

    /// The CRT frame covering the screen, if one does.
    public var crtFrame: CRTFrame? {
        switch phase {
        case .poweringOff:
            return .off(min(Self.powerOffFrameCount - 1, Int(phaseTime / Self.crtFrameTime)))
        case .poweringOn where phaseTime < Self.bloomDuration:
            return .on(min(Self.powerOnFrameCount - 1, Int(phaseTime / Self.crtFrameTime)))
        default:
            return nil
        }
    }

    /// Screen rows whose icons show (0…5): all when on, popping in one by one after the bloom.
    public var rowsShown: Int {
        switch phase {
        case .on: return Self.rows
        case .poweringOn where phaseTime >= Self.bloomDuration:
            return min(Self.rows, Int((phaseTime - Self.bloomDuration) / Self.rowStagger) + 1)
        default: return 0
        }
    }

    /// The screen shows its picture (wallpaper, tokens or a card) rather than black or a CRT frame.
    public var showsPicture: Bool {
        phase == .on || (phase == .poweringOn && phaseTime >= Self.bloomDuration)
    }

    /// Tokens are drawn and hit-testable.
    public var showsTokens: Bool { showsPicture && overlay == .none }

    /// The 2-frame static after an input change (frame index), if showing.
    public var staticFrame: Int? {
        guard staticLeft > 0 else { return nil }
        let total = Double(Self.staticFrameCount) * Self.crtFrameTime
        return min(Self.staticFrameCount - 1, Int((total - staticLeft) / Self.crtFrameTime))
    }

    /// The power LED: green while powered, amber (three blinks, then steady) for files that arrived while off.
    public var led: MonitorArt.LEDState {
        switch phase {
        case .on, .poweringOn: return .on
        case .off, .poweringOff:
            guard pendingNew > 0 else { return .off }
            if let t = ledBlinkTime {
                let inPeriod = t.truncatingRemainder(dividingBy: Self.ledBlinkPeriod)
                return inPeriod < Self.ledBlinkPeriod / 2 ? .amber : .off
            }
            return .amber
        }
    }

    /// The "+N" badge on the bezel while off, for files that arrived meanwhile.
    public var badge: String? {
        guard phase == .off || phase == .poweringOff, pendingNew > 0 else { return nil }
        return pendingNew > 99 ? "+99" : "+\(pendingNew)"
    }

    // MARK: Model helpers

    /// What the power button does: connect on the first-run prompt, otherwise toggle the display.
    public static func powerAction(_ s: DeskState) -> DeskAction {
        if s.monitor.power == .off { return .power(true) }
        return s.access == .notConnected ? .requestConnect : .power(false)
    }

    // MARK: harden
    /// The page a carry resting on INPUT turns to (spring-loading, DESIGN §2.1, as a closed drawer front or a page dot
    /// does; Errata 25): the next HDMI page, HDMI 1 after the last one and from AV; never AV itself (nothing can be
    /// dropped there). Nil when there is no other page.
    public static func springInputPage(_ s: DeskState, grid: ScreenGrid = .standard) -> Int? {
        if s.monitor.av { return 0 }
        let pages = s.pageCount(grid: grid)
        return pages > 1 ? (s.monitor.page + 1) % pages : nil
    }

    /// The input OSD: "HDMI 2 · 45" (tokens on that page) or "AV".
    public static func osdText(_ s: DeskState) -> String {
        if s.monitor.av { return "AV" }
        let count = s.tokens.occupiedCells.reduce(0) { $0 + ($1.page == s.monitor.page ? 1 : 0) }
        return "HDMI \(s.monitor.page + 1) · \(count)"
    }
}
