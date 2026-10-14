import AppKit
import QuartzCore

/// Why the loop must not run at all; any active reason pauses the display link and suppresses rendering.
public enum PauseReason: String, Hashable, Sendable, CaseIterable {
    case occluded, screensAsleep, sessionInactive, locked, userPaused
    // MARK: system (M12)
    /// Running on battery with the "pause on battery" setting (`SystemGate`; the raw values are `LoopHold`'s).
    case onBattery
}

/// The pure timing logic of `FrameLoop` (DESIGN §4.6), separate from the display link so it can be tested:
/// a fixed-step accumulator (at most `maxStepsPerTick` steps, so a long gap never explodes `dt`), a rest
/// counter, and the hard-sleep timer.
public nonisolated struct FrameClock: Hashable, Sendable {
    /// What the loop should do after a tick.
    public enum Verdict: Hashable, Sendable {
        /// Keep the display link running.
        case run
        /// `restFramesToPause` consecutive ticks without `needsFrames`: pause.
        case rest
        /// `hardSleepDelay` passed since the last activity: force the scene to rest, then pause.
        case hardSleep
    }

    /// Fixed steps per simulated second.
    public static let rate = 60
    /// The fixed simulation step.
    public static let step: Double = 1.0 / Double(rate)

    /// Simulation time after `steps` fixed steps (exact: `steps / 60`, no accumulated rounding).
    public static func time(steps: Int) -> Double {
        Double(steps) / Double(rate)
    }

    public var maxStepsPerTick = 2
    public var restFramesToPause = 30
    public var hardSleepDelay: Double = 3

    /// Fixed steps taken since creation.
    public private(set) var stepCount = 0
    /// Consecutive ticks that ended with nothing needing frames.
    public private(set) var restFrames = 0
    /// The later of the last input, wake and scripted animation end.
    public private(set) var lastActivity: Double = -.infinity
    private var accumulator: Double = 0
    private var lastTimestamp: Double?

    public init() {}

    public var simTime: Double { Self.time(steps: stepCount) }

    /// Starts a run at `now`: the next tick takes exactly one step, rest counting restarts, and the hard-sleep
    /// timer counts from `now` at the earliest.
    public mutating func wake(at now: Double) {
        lastTimestamp = nil
        accumulator = 0
        restFrames = 0
        noteActivity(at: now)
    }

    /// Records user input (or any activity that should keep the loop awake for `hardSleepDelay`).
    public mutating func noteActivity(at time: Double) {
        lastActivity = max(lastActivity, time)
    }

    /// The number of fixed steps to run for a tick at `now` (0…`maxStepsPerTick`); advances `simTime`.
    public mutating func advance(to now: Double) -> Int {
        let dt: Double
        if let last = lastTimestamp { dt = max(0, now - last) } else { dt = Self.step }
        lastTimestamp = now
        // Never bank more than the steps one tick may take: a stall drops time instead of queueing it.
        accumulator = min(accumulator + dt, Double(maxStepsPerTick) * Self.step)
        // A little slack so 60 Hz timestamp jitter does not alternate 0 and 2 steps.
        let n = min(maxStepsPerTick, Int((accumulator + Self.step * 0.05) / Self.step))
        accumulator -= Double(n) * Self.step
        stepCount += n
        return n
    }

    // MARK: harden
    /// A slow tick at `now` takes exactly `steps` fixed steps, however late its timer fired (a late timer only slows
    /// the slow animation a little, never doubles or skips a frame); the accumulator starts over.
    public mutating func advance(to now: Double, steps: Int) -> Int {
        let n = max(1, steps)
        lastTimestamp = now
        accumulator = 0
        stepCount += n
        return n
    }

    /// The fixed steps that cover `seconds` (at least one): a slow animation's next change falls on the last of them.
    public static func steps(covering seconds: Double) -> Int {
        max(1, Int((seconds / step - 1e-6).rounded(.up)))
    }

    /// Ends a tick: counts rest frames and checks the hard-sleep timer.
    public mutating func finishTick(at now: Double, needsFrames: Bool) -> Verdict {
        restFrames = needsFrames ? 0 : restFrames + 1
        if now - lastActivity >= hardSleepDelay { return .hardSleep }
        return restFrames >= restFramesToPause ? .rest : .run
    }
}

/// Whatever the loop drives: one `SceneHost` per display.
@MainActor
public protocol FrameLoopHost: AnyObject {
    /// One fixed simulation step of `dt` seconds.
    func frameLoopStep(_ dt: Double)
    /// Renders and presents the current state.
    func frameLoopRender()
    /// True while anything still moves on its own.
    var frameLoopNeedsFrames: Bool { get }
    /// True while a scripted, bounded animation runs (CRT, AV logo, print-in, a toast) or a drag is in hand:
    /// each tick counts as activity, so hard sleep comes 3 s after it ends, never in the middle.
    var frameLoopScriptedAnimating: Bool { get }
    /// Hard sleep: settle everything now.
    func frameLoopForceRest()
    // MARK: harden
    /// Non-nil while the only thing moving changes its picture at a low rate of its own (the AV logo at 8 fps): the
    /// time until it next changes, a whole number of fixed steps. The loop then ticks on a timer just then, taking
    /// exactly those steps, instead of at 60 Hz, so an idle desk showing AV costs next to nothing and shows every
    /// change once.
    var frameLoopSlowFrameInterval: Double? { get }
}

extension FrameLoopHost {
    public var frameLoopSlowFrameInterval: Double? { nil }
}

/// Drives a host from the view's `CADisplayLink` (macOS 14) at up to 60 Hz with a fixed 1/60 s step, and
/// stops the link whenever nothing moves (DESIGN §4.6, §5): after 30 rest frames (nothing needs frames: no
/// element animating, no carry), or 3 s after the later of the last input and the end of the last scripted
/// animation (hard sleep: the host settles everything), or while any `PauseReason` holds. Hover and tooltips
/// render single frames (`renderOnce`) and never start the link. While only a slow animation runs (the AV logo,
/// `frameLoopSlowFrameInterval`), the link rests and a timer ticks at each of that animation's own frames, stepping
/// exactly the fixed steps up to it (Errata 25); input that starts anything faster brings the link back.
public final class FrameLoop {
    public weak var host: (any FrameLoopHost)?
    public private(set) var clock = FrameClock()
    public private(set) var pauseReasons: Set<PauseReason> = []
    /// Caps the rate at 30 Hz (Low Power Mode).
    public var lowPower = false {
        didSet { applyFrameRate() }
    }

    private var link: CADisplayLink?
    private let proxy = DisplayLinkProxy()
    // MARK: harden
    /// The next slow tick, while only a slow animation runs.
    private var slowTimer: Timer?
    /// Ticks taken on the slow timer so far (tests, measurements).
    public private(set) var slowTicks = 0

    public init() {
        proxy.loop = self
    }

    /// True while the display link is ticking.
    public var isRunning: Bool { link.map { !$0.isPaused } ?? false }

    /// True while the loop ticks slowly on a timer (only a slow animation runs; the link rests).
    public var isTickingSlowly: Bool { slowTimer != nil }

    /// Creates the display link for `view` (it follows the view across displays). Starts paused.
    public func attach(to view: NSView) {
        invalidate()
        let l = view.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        l.isPaused = true
        l.add(to: .main, forMode: .common)
        link = l
        applyFrameRate()
    }

    /// Stops and releases the display link (the link retains its target until then).
    public func invalidate() {
        cancelSlowTicks()
        link?.invalidate()
        link = nil
    }

    /// Starts ticking (no-op while paused for a reason). While the loop ticks slowly and still only a slow animation
    /// runs, it keeps its pace (the activity is noted).
    public func wake() {
        let now = CACurrentMediaTime()
        clock.noteActivity(at: now)
        guard pauseReasons.isEmpty, let link, link.isPaused else { return }
        if slowTimer != nil, host?.frameLoopSlowFrameInterval != nil { return }
        cancelSlowTicks()
        clock.wake(at: now)
        link.isPaused = false
    }

    /// Records input: keeps the loop out of hard sleep for another `hardSleepDelay`.
    public func noteInput() {
        clock.noteActivity(at: CACurrentMediaTime())
    }

    /// Renders one frame without stepping (hover, clock minute, resume). Coalesced into the next tick
    /// while running; dropped while paused for a reason.
    public func renderOnce() {
        guard pauseReasons.isEmpty, !isRunning else { return }
        host?.frameLoopRender()
    }

    /// Adds or removes a pause reason. Clearing the last reason resumes what was queued meanwhile (a print-in, a
    /// toast, the CRT) by waking the loop when the host needs frames, and otherwise renders one frame.
    public func setPaused(_ reason: PauseReason, _ paused: Bool) {
        let wasPaused = !pauseReasons.isEmpty
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        if !pauseReasons.isEmpty {
            cancelSlowTicks()
            link?.isPaused = true
        } else if wasPaused {
            if host?.frameLoopNeedsFrames == true { wake() } else { renderOnce() }
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard pauseReasons.isEmpty, let host else {
            link.isPaused = true
            return
        }
        let now = link.timestamp
        switch frame(at: now, host: host, steps: nil) {
        case .run:
            // MARK: harden: only a slow animation left: rest the link and tick at its own frames.
            if let interval = host.frameLoopSlowFrameInterval {
                link.isPaused = true
                scheduleSlowTick(steps: FrameClock.steps(covering: interval), from: now)
            }
        case .rest, .hardSleep:
            link.isPaused = true
        }
    }

    /// One frame at `now`: the fixed steps that fell due (or exactly `steps`, a slow tick's), a render, and the verdict
    /// (a hard sleep settles the host and renders its rest).
    private func frame(at now: Double, host: any FrameLoopHost, steps exact: Int?) -> FrameClock.Verdict {
        let steps = exact.map { clock.advance(to: now, steps: $0) } ?? clock.advance(to: now)
        for _ in 0..<steps { host.frameLoopStep(FrameClock.step) }
        host.frameLoopRender()
        if host.frameLoopScriptedAnimating { clock.noteActivity(at: now) }
        let verdict = clock.finishTick(at: now, needsFrames: host.frameLoopNeedsFrames)
        if verdict == .hardSleep {
            host.frameLoopForceRest()
            host.frameLoopRender()
        }
        return verdict
    }

    // MARK: harden: slow ticks

    /// Ticks once more `steps` fixed steps after `start` (a tick's time) on a timer; the link rests meanwhile.
    private func scheduleSlowTick(steps: Int, from start: Double) {
        slowTimer?.invalidate()
        let due = start + Double(steps) * FrameClock.step
        let timer = Timer(timeInterval: max(0.001, due - CACurrentMediaTime()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.slowTick(at: CACurrentMediaTime()) }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        slowTimer = timer
    }

    /// One slow tick at `now`: exactly the steps up to the slow animation's next change (so each tick shows one, however
    /// late the timer), a render; then the next slow tick, the link again when something faster started, or rest
    /// once nothing moves.
    func slowTick(at now: Double) {
        cancelSlowTicks()
        guard pauseReasons.isEmpty, let host, link?.isPaused != false else { return }
        slowTicks += 1
        let steps = FrameClock.steps(covering: host.frameLoopSlowFrameInterval ?? FrameClock.step)
        let verdict = frame(at: now, host: host, steps: steps)
        guard verdict != .hardSleep, host.frameLoopNeedsFrames else { return }
        if let next = host.frameLoopSlowFrameInterval {
            scheduleSlowTick(steps: FrameClock.steps(covering: next), from: now)
        } else {
            link?.isPaused = false
        }
    }

    private func cancelSlowTicks() {
        slowTimer?.invalidate()
        slowTimer = nil
    }

    private func applyFrameRate() {
        link?.preferredFrameRateRange = lowPower
            ? CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
            : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }
}

/// Breaks the link → target retain cycle.
private final class DisplayLinkProxy: NSObject {
    weak var loop: FrameLoop?

    @objc func tick(_ link: CADisplayLink) {
        loop?.tick(link)
    }
}
