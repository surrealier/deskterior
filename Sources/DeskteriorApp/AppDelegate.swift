import AppKit
import DeskCore
import DeskFiles
import DeskScene
import Metal

/// The app shell: desk (or `--windowed`) window, status item, system observers, and the dev flags that act
/// after launch (`--print-window-id`, `--exit-after`). Headless runs never get here (`runHeadless`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    private var displays: DisplayManager?
    private var statusMenu: StatusMenu?
    private var observers: SystemObservers?
    private(set) var isUserPaused = false

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else { Self.fail("no Metal device") }
        installKeyRoutingMenu()

        let displays = DisplayManager(options: options, device: device)
        displays.contextMenu = { [weak self] in self?.makeContextMenu() }
        do {
            try displays.start()
        } catch {
            Self.fail("could not start the desk: \(error)")
        }
        self.displays = displays

        statusMenu = StatusMenu(
            isPaused: { [weak self] in self?.isUserPaused ?? false },
            togglePause: { [weak self] in self?.togglePause() }
        )
        if let window = displays.window, let host = displays.host {
            observers = SystemObservers(window: window, loop: host.loop) { [weak displays] in
                displays?.refreshGrid()
            }
        }

        let mode = options.windowed.map { "windowed \($0)" } ?? "desk (level \(options.level.rawValue))"
        Log.info("Deskterior \(DeskCore.version), \(mode), bundle id \(AppIdentity.bundleID)")
        if options.printWindowID, let window = displays.window {
            print(window.windowNumber)
            fflush(stdout)
        }
        if let seconds = options.exitAfter {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        options.windowed != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        observers?.invalidate()
        displays?.invalidate()
    }

    func togglePause() {
        setUserPaused(!isUserPaused)
    }

    func setUserPaused(_ paused: Bool) {
        guard paused != isUserPaused else { return }
        isUserPaused = paused
        displays?.setUserPaused(paused)
        Log.info(paused ? "desk paused" : "desk resumed")
    }

    /// The bare-desk right-click menu (M2: Pause Desk, Quit).
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let pause = NSMenuItem(title: "Pause Desk", action: #selector(pauseFromMenu), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        let quit = #selector(NSApplication.terminate(_:))
        menu.addItem(NSMenuItem(title: "Quit Deskterior", action: quit, keyEquivalent: ""))
        return menu
    }

    @objc private func pauseFromMenu() {
        setUserPaused(true)
    }

    /// An accessory app shows no menu bar (DESIGN Errata 1); this hidden main menu only routes key equivalents.
    private func installKeyRoutingMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = #selector(NSApplication.terminate(_:))
        appMenu.addItem(NSMenuItem(title: "Quit Deskterior", action: quit, keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Deskterior: \(message)\n".utf8))
        exit(1)
    }
}

extension AppDelegate {
    /// `--headless`: steps `--frames` fixed frames offscreen on the emulated display and, with
    /// `--snapshot-dir`, writes `calibration.png` (art px) and `calibration@<N>x.png`. Returns the exit code.
    static func runHeadless(_ options: LaunchOptions) -> Int32 {
        let display = options.emulatedDisplay
        let grid = PixelGrid(display: display.geometry(), pixelSize: options.pixelSize)
        guard let device = MTLCreateSystemDefaultDevice() else {
            FileHandle.standardError.write(Data("Deskterior: no Metal device\n".utf8))
            return 1
        }
        do {
            let host = try SceneHost(grid: grid, device: device)
            let driver = OffscreenDriver(host: host)
            driver.run(frames: options.frames)
            let frame = try driver.snapshot()
            print("headless \(display): S \(grid.scale), canvas \(grid.artSize), crop L\(grid.cropLeft) "
                + "T\(grid.cropTop) R\(grid.cropRight) B\(grid.cropBottom), core \(grid.coreRect), "
                + "frames \(options.frames)")
            if let dir = options.snapshotDir {
                let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
                let writer = try ArtifactWriter(directory: url)
                for png in Snapshotter.pngs(frame, name: "calibration", scale: options.snapshotScale) {
                    print("wrote \(try writer.write(png.data, named: png.name).path)")
                }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Deskterior: headless run failed: \(error)\n".utf8))
            return 1
        }
    }
}
