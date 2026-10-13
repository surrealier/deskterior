import CoreGraphics
import DeskCore
import DeskFiles
import DeskPixels
import Foundation

/// `deskterior-assets fixture` and `mirror-dump`: fixture files for test desktops, and the mirror pipeline
/// (scan → reconcile → JSON) run against a scratch folder. Both refuse the real desktop.
///
///   deskterior-assets fixture --out DIR
///       small PNG pictures, an icon-like PNG with alpha and two PDFs, for scripts/make-fixture-desktop.sh
///   deskterior-assets mirror-dump --folder DIR [--state-dir DIR] [--summary] [--watch SECONDS]
///       prints the reconciled layout as desk.json; --state-dir loads and saves a layout there;
///       --watch keeps mirroring and prints one line per change
enum MirrorTools {
    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    static let usage = """
        usage: deskterior-assets fixture --out DIR
               deskterior-assets mirror-dump --folder DIR [--state-dir DIR] [--summary] [--watch SECONDS]
        """

    // MARK: fixture

    static func fixture(_ args: [String]) throws {
        guard let out = value("--out", in: args) else { throw UsageError(description: usage) }
        let writer = try ArtifactWriter(directory: URL(fileURLWithPath: out, isDirectory: true))
        let files: [(String, Data)] = [
            ("photo-sunset.png", PNGCodec.encode(try sunset(width: 64, height: 48))),
            ("photo-forest.png", PNGCodec.encode(try forest(width: 48, height: 64))),
            ("icon-badge.png", PNGCodec.encode(try badge(size: 64))),
            ("diagram.png", PNGCodec.encode(try diagram(width: 80, height: 60))),
            ("report.pdf", try pdf(pages: 1)),
            ("slides.pdf", try pdf(pages: 3)),
        ]
        for (name, data) in files {
            guard !data.isEmpty else { throw UsageError(description: "could not encode \(name)") }
            print(try writer.write(data, named: name).path)
        }
    }

    private static func context(_ w: Int, _ h: Int) throws -> CGContext {
        guard let ctx = CGBridge.makeContext(width: w, height: h) else {
            throw UsageError(description: "no bitmap context")
        }
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        return ctx
    }

    private static func image(_ ctx: CGContext) throws -> PixelBuffer {
        guard let b = CGBridge.pixelBuffer(from: ctx) else { throw UsageError(description: "no pixels") }
        return b
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: CGBridge.colorSpace, components: [r, g, b, a])!
    }

    private static func gradient(_ ctx: CGContext, _ top: CGColor, _ bottom: CGColor, _ rect: CGRect) {
        let g = CGGradient(colorsSpace: CGBridge.colorSpace, colors: [bottom, top] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        ctx.restoreGState()
    }

    private static func sunset(width w: Int, height h: Int) throws -> PixelBuffer {
        let ctx = try context(w, h)
        let W = CGFloat(w), H = CGFloat(h)
        gradient(ctx, rgb(0.25, 0.2, 0.55), rgb(0.98, 0.6, 0.3), CGRect(x: 0, y: H * 0.3, width: W, height: H * 0.7))
        ctx.setFillColor(rgb(1, 0.85, 0.4))
        ctx.fillEllipse(in: CGRect(x: W * 0.55, y: H * 0.3, width: W * 0.25, height: W * 0.25))
        gradient(ctx, rgb(0.15, 0.3, 0.45), rgb(0.05, 0.12, 0.2), CGRect(x: 0, y: 0, width: W, height: H * 0.32))
        return try image(ctx)
    }

    private static func forest(width w: Int, height h: Int) throws -> PixelBuffer {
        let ctx = try context(w, h)
        let W = CGFloat(w), H = CGFloat(h)
        gradient(ctx, rgb(0.55, 0.8, 0.95), rgb(0.85, 0.93, 0.98), CGRect(x: 0, y: 0, width: W, height: H))
        for (i, x) in stride(from: -4.0, to: Double(w), by: 11).enumerated() {
            let green = rgb(0.1, 0.35 + 0.05 * CGFloat(i % 3), 0.15)
            ctx.setFillColor(green)
            ctx.move(to: CGPoint(x: x, y: 8))
            ctx.addLine(to: CGPoint(x: x + 9, y: H * 0.75 - CGFloat(i % 2) * 8))
            ctx.addLine(to: CGPoint(x: x + 18, y: 8))
            ctx.fillPath()
        }
        ctx.setFillColor(rgb(0.35, 0.25, 0.15))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: 9))
        return try image(ctx)
    }

    /// A rounded app-icon-like badge with a soft shadow on a transparent background.
    private static func badge(size: Int) throws -> PixelBuffer {
        let ctx = try context(size, size)
        let S = CGFloat(size)
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: rgb(0, 0, 0, 0.5))
        ctx.setFillColor(rgb(0.2, 0.45, 0.85))
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: S * 0.12, y: S * 0.12, width: S * 0.76, height: S * 0.76),
            cornerWidth: S * 0.18, cornerHeight: S * 0.18, transform: nil
        ))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setFillColor(rgb(1, 1, 1))
        ctx.fillEllipse(in: CGRect(x: S * 0.32, y: S * 0.32, width: S * 0.36, height: S * 0.36))
        ctx.setFillColor(rgb(0.95, 0.3, 0.3))
        ctx.fillEllipse(in: CGRect(x: S * 0.42, y: S * 0.42, width: S * 0.16, height: S * 0.16))
        return try image(ctx)
    }

    private static func diagram(width w: Int, height h: Int) throws -> PixelBuffer {
        let ctx = try context(w, h)
        ctx.setFillColor(rgb(0.97, 0.97, 0.95))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(rgb(0.2, 0.2, 0.3))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 8, y: 30, width: 24, height: 18))
        ctx.stroke(CGRect(x: 48, y: 30, width: 24, height: 18))
        ctx.stroke(CGRect(x: 28, y: 6, width: 24, height: 14))
        ctx.move(to: CGPoint(x: 32, y: 39))
        ctx.addLine(to: CGPoint(x: 48, y: 39))
        ctx.strokePath()
        return try image(ctx)
    }

    /// A small A6 PDF with stripes standing in for text.
    private static func pdf(pages: Int) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 298, height: 420)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw UsageError(description: "no PDF context") }
        for page in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(rgb(0.2, 0.3, 0.6))
            ctx.fill(CGRect(x: 24, y: 360, width: 180, height: 22))
            ctx.setFillColor(rgb(0.4, 0.4, 0.45))
            for line in 0..<(14 - page * 3) {
                let width: CGFloat = line % 4 == 3 ? 140 : 250
                ctx.fill(CGRect(x: 24, y: 320 - CGFloat(line) * 18, width: width, height: 6))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    // MARK: mirror-dump

    static func mirrorDump(_ args: [String]) throws {
        guard let folderArg = value("--folder", in: args) else { throw UsageError(description: usage) }
        let resolution = DesktopLocator.resolve(override: folderArg)
        let folder: URL
        do throws(SafetyGuard.Refusal) {
            folder = try SafetyGuard.mirrorFolder(resolution, mode: .tool)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(error.exitCode)
        }
        let store = try value("--state-dir", in: args).map {
            try StateStore(directory: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true))
        }

        var state = store?.load().document?.makeState() ?? DeskState()
        let scanner = DesktopScanner(root: folder)
        let t0 = Date()
        let snapshot = try scanner.scan()
        let t1 = Date()
        let effects = reduce(&state, .snapshot(snapshot, now: snapshot.scannedAt), ReduceEnv(now: snapshot.scannedAt))
        let t2 = Date()
        try store?.save(state)
        let violations = state.violations()
        log(String(
            format: "scanned %d items in %.1f ms, reconciled in %.1f ms, %d effects, %d pages%@",
            snapshot.entries.count, t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, effects.count,
            state.pageCount(), violations.isEmpty ? "" : ", INVARIANT VIOLATIONS: \(violations)"
        ))

        if args.contains("--summary") {
            printSummary(state)
        } else {
            let json = try DeskDocument(state: state, savedAt: snapshot.scannedAt).encoded()
            FileHandle.standardOutput.write(json)
            print()
        }

        if let seconds = value("--watch", in: args).flatMap(Double.init), seconds > 0 {
            try watch(folder: folder, state: state, store: store, seconds: seconds)
        }
        if !violations.isEmpty { exit(1) }
    }

    private static func printSummary(_ state: DeskState) {
        print("root: \(state.root?.path ?? "-")  tokens: \(state.tokens.count)  pages: \(state.pageCount())")
        for key in Placement.byName(state.tokens.sortedKeys, in: state.tokens) {
            let r = state.tokens[key]!
            print("  \(r.location)\t\(r.meta.kind.rawValue)\t\(r.meta.displayName)")
        }
    }

    /// Mirrors for `seconds`, printing one line per event.
    private static func watch(folder: URL, state: DeskState, store: StateStore?, seconds: Double) throws {
        final class Shared: @unchecked Sendable {
            let lock = NSLock()
            var state: DeskState
            init(_ s: DeskState) { state = s }
        }
        let shared = Shared(state)
        let start = Date()
        let watcher = DesktopWatcher(scanner: DesktopScanner(root: folder)) { event in
            switch event {
            case let .failed(failure):
                log("scan failed: \(failure)")
            case let .snapshot(snapshot):
                shared.lock.withLock {
                    let before = shared.state
                    let events = Reconciler.reconcile(&shared.state, snapshot, now: snapshot.scannedAt)
                    let t = String(format: "%7.3f", Date().timeIntervalSince(start))
                    for e in events { print("[\(t)s] \(describe(e, before: before, after: shared.state))") }
                    fflush(stdout)
                    try? store?.save(shared.state)
                }
            }
        }
        watcher.start(initialScan: false)
        log("watching \(folder.path) for \(seconds) s")
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + seconds)
        watcher.stop()
    }

    private static func describe(_ e: DeskEvent, before: DeskState, after: DeskState) -> String {
        func name(_ k: TokenKey, _ s: DeskState) -> String { s.tokens.meta(of: k)?.displayName ?? "\(k)" }
        switch e {
        case let .added(k, loc, arrival): return "+ \(name(k, after)) → \(loc) (\(arrival.rawValue))"
        case let .removed(_, loc, n): return "- \(TextLayout.nfc(n)) from \(loc)"
        case let .renamed(k, from, to): return "~ \(TextLayout.nfc(from)) → \(TextLayout.nfc(to)) at \(after.tokens.location(of: k)!)"
        case let .rekeyed(old, new): return "= \(name(new, after)) re-keyed \(old) → \(new) (safe save)"
        case let .updated(k): return "* \(name(k, after)) updated"
        case .reset: return "! folder changed; layout reset"
        }
    }

    // MARK: Helpers

    private static func value(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}
