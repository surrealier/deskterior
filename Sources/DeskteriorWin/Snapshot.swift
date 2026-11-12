import DeskCore
import DeskFiles
import DeskPixels
import DeskScene
import Foundation

/// `--snapshot`: the desk rendered headless (docs/WINDOWS.md WP6). The folder is scanned once (read only), the
/// scene runs `frames` fixed steps (tokens fall and settle), and the frame the display would show is written as PNG
/// to the path asked for, which is the only file this run writes.
enum Snapshot {
    struct Report: CustomStringConvertible {
        var folder: String
        var tokens: Int
        var art: ArtSize
        var device: (Int, Int)
        var refused: [String]

        var description: String {
            "snapshot: \(tokens) item(s) from \(folder); art \(art.w)x\(art.h), device \(device.0)x\(device.1)"
                + (refused.isEmpty ? "" : "; refused \(refused)")
        }
    }

    static func run(_ options: WinOptions, environment: [String: String]) throws -> Report {
        let folder = options.resolvedFolder(environment: environment)
        let grid = WinOptions.grid(width: options.width, height: options.height, scale: options.scale)
        let session = try WinSession(grid: grid, folder: folder, stateDirectory: nil)
        session.start(connect: false)
        try session.scanNow()
        let driver = OffscreenDriver(host: session.host)
        driver.run(frames: options.frames)
        let frame = try driver.deviceFrame()
        let out = URL(fileURLWithPath: options.snapshot ?? "deskterior.png")
        try PNGCodec.encode(frame).write(to: out, options: .atomic)
        return Report(
            folder: DesktopLocator.canonicalPath(folder), tokens: session.state.tokens.records.count, art: grid.artSize,
            device: (frame.width, frame.height), refused: session.refusedEffects
        )
    }
}
