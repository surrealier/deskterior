import AppKit
import DeskCore
import DeskFiles
import DeskPixels
import QuickLookThumbnailing

/// Real icons for tokens (DESIGN §3.4): Quick Look thumbnails (`.thumbnail`, 64 px) for images, video and
/// PDF; `NSWorkspace.icon(forFile:)` for everything else; then `IconPixelator` at 16 and 12 px, cached in
/// `IconCache`. At most `maxInFlight` requests run at once, visible tokens first. Dataless iCloud items get
/// `.kindOnly` without touching the file, so nothing is ever downloaded.
final class IconProvider {
    struct Request: Sendable, Hashable {
        var key: TokenKey
        var url: URL
        var kind: FileKind
        var modified: Date?
        var size: Int64?
        var isDataless: Bool

        init(key: TokenKey, url: URL, meta: TokenMeta) {
            self.key = key
            self.url = url
            kind = meta.kind
            modified = meta.modified
            size = meta.size
            isDataless = meta.isDataless
        }
    }

    enum Result: Sendable, Equatable {
        /// 16×16 icon and 12×12 mini.
        case pixels(icon: PixelBuffer, mini: PixelBuffer)
        /// Use the hand-drawn kind icon.
        case kindOnly
    }

    static let maxInFlight = 4
    static let sourcePixels = 64

    /// Delivered on the main actor, once per request.
    var onIcon: (TokenKey, Result) -> Void
    private let cache: IconCache?
    private var pending: [Request] = []
    private var queued = Set<TokenKey>()
    private var inFlight = 0

    init(cache: IconCache?, onIcon: @escaping (TokenKey, Result) -> Void = { _, _ in }) {
        self.cache = cache
        self.onIcon = onIcon
    }

    /// Queues `requests`; those in `visible` jump ahead of everything already waiting.
    func request(_ requests: [Request], visible: Set<TokenKey> = []) {
        let fresh = requests.filter { queued.insert($0.key).inserted }
        let front = fresh.filter { visible.contains($0.key) }
        let back = fresh.filter { !visible.contains($0.key) }
        pending = front + pending + back
        pump()
    }

    /// Drops everything not yet started.
    func cancelPending() {
        for r in pending { queued.remove(r.key) }
        pending.removeAll()
    }

    // MARK: Private

    private func pump() {
        while inFlight < Self.maxInFlight, !pending.isEmpty {
            let r = pending.removeFirst()
            inFlight += 1
            start(r)
        }
    }

    private func finish(_ r: Request, _ result: Result) {
        inFlight -= 1
        queued.remove(r.key)
        onIcon(r.key, result)
        pump()
    }

    private func start(_ r: Request) {
        if r.isDataless {
            finish(r, .kindOnly)
            return
        }
        let cache = cache
        DispatchQueue.global(qos: .utility).async {
            if let cached = Self.cached(r, cache) {
                Self.deliver(self, r, cached)
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.render(r) }
            }
        }
    }

    /// Quick Look for pictures and pages, the workspace icon otherwise (or when Quick Look has nothing).
    private func render(_ r: Request) {
        let cache = cache
        guard Self.usesThumbnail(r.kind) else {
            finishWithWorkspaceIcon(r)
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: r.url, size: CGSize(width: Self.sourcePixels, height: Self.sourcePixels), scale: 1,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            if let image = representation?.cgImage, let source = PixelBuffer(cgImage: image) {
                Self.deliver(self, r, Self.pixelate(source, r, cache))
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.finishWithWorkspaceIcon(r) }
                }
            }
        }
    }

    private func finishWithWorkspaceIcon(_ r: Request) {
        let cache = cache
        let image = NSWorkspace.shared.icon(forFile: r.url.path)
        var rect = CGRect(x: 0, y: 0, width: Self.sourcePixels, height: Self.sourcePixels)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let source = PixelBuffer(cgImage: cg)
        else {
            finish(r, .kindOnly)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            Self.deliver(self, r, Self.pixelate(source, r, cache))
        }
    }

    /// Images, video and PDF show their content; everything else its Finder icon.
    nonisolated static func usesThumbnail(_ kind: FileKind) -> Bool {
        switch kind {
        case .image, .screenshot, .video, .pdf: true
        default: false
        }
    }

    nonisolated private static func deliver(_ provider: IconProvider, _ r: Request, _ result: Result) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { provider.finish(r, result) }
        }
    }

    nonisolated private static func cacheKey(_ r: Request, pixels: Int) -> String {
        IconCache.key(
            inode: r.key.inode, modified: r.modified, size: r.size, kind: r.kind, pixels: pixels,
            paletteVersion: IconPixelator.version
        )
    }

    nonisolated private static func cached(_ r: Request, _ cache: IconCache?) -> Result? {
        guard let cache,
              let icon = cache.load(cacheKey(r, pixels: 16)).flatMap(PNGCodec.decode),
              let mini = cache.load(cacheKey(r, pixels: 12)).flatMap(PNGCodec.decode)
        else { return nil }
        return .pixels(icon: icon, mini: mini)
    }

    nonisolated private static func pixelate(_ source: PixelBuffer, _ r: Request, _ cache: IconCache?) -> Result {
        let style = IconPixelator.style(for: r.kind)
        guard let icon = IconPixelator.pixelate(source, size: 16, style: style),
              let mini = IconPixelator.pixelate(source, size: 12, style: style)
        else { return .kindOnly }
        try? cache?.store(PNGCodec.encode(icon), for: cacheKey(r, pixels: 16))
        try? cache?.store(PNGCodec.encode(mini), for: cacheKey(r, pixels: 12))
        return .pixels(icon: icon, mini: mini)
    }
}
