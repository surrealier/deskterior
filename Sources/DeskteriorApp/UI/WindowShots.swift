import AppKit
import DeskCore
import DeskFiles
import DeskPixels

/// `--window-shots DIR` (windowed development runs): PNGs of the app's own windows (Settings, About, Safe Mode, the
/// welcome card, notes, Find Item, Memos, Arrange Desk) drawn by the windows themselves (`cacheDisplay`, no Screen Recording permission), plus the
/// Peek "× Done" button's pixels ×3, written 1.5 s after launch through `ArtifactWriter` (never into a desktop).
enum WindowShots {
    static func schedule(_ options: LaunchOptions, windows: @escaping () -> [(name: String, window: NSWindow)]) {
        guard options.mode == .windowed, let dir = options.windowShots else { return }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        let mirrored = options.desktopFolder.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            do {
                let writer = try ArtifactWriter(directory: url, mirrored: mirrored)
                for (name, window) in windows() {
                    guard let png = png(of: window) else { continue }
                    print("wrote \(try writer.write(png, named: "window-\(name).png").path)")
                }
                if options.show.contains("peek"), let art = PeekDoneButton.art(),
                   let png = art.scaledNearest(3).makeCGImage().flatMap(pngData) {
                    print("wrote \(try writer.write(png, named: "peek-done@3x.png").path)")
                }
            } catch {
                FileHandle.standardError.write(Data("Deskterior: window shots failed: \(error)\n".utf8))
            }
        }
    }

    /// The window's content as the window draws it (frame chrome excluded).
    static func png(of window: NSWindow) -> Data? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
