#if canImport(AppKit)
import AppKit
import QuartzCore

/// The macOS `FrameTicker`: the view's `CADisplayLink` (it follows the view across displays), 60 Hz or 30 Hz in
/// Low Power Mode.
public final class DisplayLinkTicker: FrameTicker {
    private var link: CADisplayLink?
    private let proxy = DisplayLinkProxy()
    public var onTick: ((Double) -> Void)?

    public init(view: NSView) {
        proxy.ticker = self
        let l = view.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        l.isPaused = true
        l.add(to: .main, forMode: .common)
        link = l
        applyFrameRate()
    }

    public var isPaused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    public var lowPower = false {
        didSet { applyFrameRate() }
    }

    public func invalidate() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        onTick?(link.timestamp)
    }

    private func applyFrameRate() {
        link?.preferredFrameRateRange = lowPower
            ? CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
            : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }
}

/// Breaks the link → target retain cycle.
private final class DisplayLinkProxy: NSObject {
    weak var ticker: DisplayLinkTicker?

    @objc func tick(_ link: CADisplayLink) {
        ticker?.tick(link)
    }
}

extension FrameLoop {
    /// Creates the display link for `view` (it follows the view across displays). Starts paused.
    public func attach(to view: NSView) {
        attach(ticker: DisplayLinkTicker(view: view))
    }
}
#endif
