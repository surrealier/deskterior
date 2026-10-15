import AppKit
import DeskCore
import DeskFiles
import DeskPixels
import QuickLookThumbnailing

/// Real icons for tokens (DESIGN §3.4): Quick Look thumbnails (`.thumbnail`, 64 px) for images, video and
/// PDF; `NSWorkspace.icon(forFile:)` for everything else (an alias shows its target's icon, without Finder's arrow:
/// the desk draws its own alias mark; Erratum 29); then `IconPixelator` at 16 and 12 px, cached in
/// `IconCache`. At most `maxInFlight` requests run at once, visible tokens first. Dataless iCloud items get
/// `.kindOnly` without touching the file, so nothing is ever downloaded. A file that was renamed or replaced
/// while its icon rendered comes back `.stale` (nothing is cached for it); request it again at its new URL.
final class IconProvider {
    struct Request: Sendable, Hashable {
        var key: TokenKey
        var url: URL
        var kind: FileKind
        var modified: Date?
        var size: Int64?
        var isDataless: Bool
        /// A Finder alias (or a symbolic link): its target's icon is drawn.
        var isAlias: Bool

        init(key: TokenKey, url: URL, meta: TokenMeta) {
            self.key = key
            self.url = url
            kind = meta.kind
            modified = meta.modified
            size = meta.size
            isDataless = meta.isDataless
            isAlias = meta.isAlias
        }
    }

    enum Result: Sendable, Equatable {
        /// 16×16 icon and 12×12 mini.
        case pixels(icon: PixelBuffer, mini: PixelBuffer)
        /// Use the hand-drawn kind icon.
        case kindOnly
        /// The file left `url` while rendering; nothing was cached.
        case stale
    }

    static let maxInFlight = 4
    static let sourcePixels = 64

    /// Delivered on the main actor, once per request.
    var onIcon: (TokenKey, Result) -> Void
    private let cache: IconCache?
    /// Waiting requests from `head` on (a queue without O(n) removals).
    private var pending: [Request] = []
    private var head = 0
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
        pending = front + pending[head...] + back
        head = 0
        pump()
    }

    /// Nothing waiting and nothing rendering.
    var isIdle: Bool { inFlight == 0 && head >= pending.count }

    /// Drops everything not yet started.
    func cancelPending() {
        for r in pending[head...] { queued.remove(r.key) }
        pending.removeAll()
        head = 0
    }

    // MARK: Private

    /// Starts requests up to `maxInFlight`. Dataless items are answered in the loop (no recursion, however many).
    private func pump() {
        while inFlight < Self.maxInFlight, head < pending.count {
            let r = pending[head]
            head += 1
            if r.isDataless {
                queued.remove(r.key)
                onIcon(r.key, .kindOnly)
                continue
            }
            inFlight += 1
            start(r)
        }
        if head > 64, head * 2 > pending.count {
            pending.removeFirst(head)
            head = 0
        }
    }

    private func finish(_ r: Request, _ result: Result) {
        inFlight -= 1
        queued.remove(r.key)
        onIcon(r.key, result)
        pump()
    }

    private func start(_ r: Request) {
        let cache = cache
        DispatchQueue.global(qos: .utility).async {
            if let cached = Self.cached(r, cache) {
                Self.deliver(self, r, cached)
                return
            }
            // An alias's target is looked up here, off the main thread (it reads the alias file).
            let target = r.isAlias ? Self.aliasTarget(r.url) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.render(r, iconOf: target) }
            }
        }
    }

    /// Quick Look for pictures and pages, the workspace icon otherwise (or when Quick Look has nothing). An alias
    /// whose target was found shows the target's workspace icon (`iconOf`).
    private func render(_ r: Request, iconOf target: URL? = nil) {
        let cache = cache
        guard Self.usesThumbnail(r.kind), !r.isAlias else {
            finishWithWorkspaceIcon(r, iconOf: target)
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: r.url, size: CGSize(width: Self.sourcePixels, height: Self.sourcePixels), scale: 1,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            if let image = representation?.cgImage, let source = PixelBuffer(cgImage: image) {
                Self.deliver(self, r, Self.isStillAt(r) ? Self.pixelate(source, r, cache) : .stale)
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.finishWithWorkspaceIcon(r) }
                }
            }
        }
    }

    private func finishWithWorkspaceIcon(_ r: Request, iconOf target: URL? = nil) {
        let cache = cache
        // `icon(forFile:)` draws a generic icon for a missing path; never cache that under the token's key.
        guard Self.isStillAt(r) else {
            finish(r, .stale)
            return
        }
        let image = NSWorkspace.shared.icon(forFile: (target ?? r.url).path)
        var rect = CGRect(x: 0, y: 0, width: Self.sourcePixels, height: Self.sourcePixels)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let source = PixelBuffer(cgImage: cg)
        else {
            finish(r, .kindOnly)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            Self.deliver(self, r, Self.isStillAt(r) ? Self.pixelate(source, r, cache) : .stale)
        }
    }

    /// The request's file is still at its URL (same inode).
    nonisolated private static func isStillAt(_ r: Request) -> Bool {
        var st = stat()
        return lstat(r.url.path, &st) == 0 && UInt64(st.st_ino) == r.key.inode
    }

    // MARK: alias (Erratum 29)

    /// Where the Finder alias at `url` points, by the path its bookmark data stored, when an item is there: read from
    /// the alias file without resolving it (no search, no mounting, no UI). Nil for a symbolic link, a broken alias
    /// or one whose target moved: then the alias file's own workspace icon is drawn (the target's, with Finder's
    /// arrow; the desk's mark covers the arrow's corner).
    nonisolated static func aliasTarget(_ url: URL) -> URL? {
        guard let data = try? URL.bookmarkData(withContentsOf: url),
              let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path
        else { return nil }
        var st = stat()
        return lstat(path, &st) == 0 ? URL(fileURLWithPath: path) : nil
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
