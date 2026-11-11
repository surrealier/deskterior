#if os(Windows)
import DeskCore
import DeskFiles
import DeskScene
import Foundation
import WinSDK

// The window (docs/WINDOWS.md WP6): one top-level window whose client area is the desk. Frames come from the soft
// renderer (`PixelPresenter`) and are drawn with `StretchDIBits` at the grid's integer scale (nearest neighbour,
// crop applied); pointer input becomes `InputEvent`s in art coordinates. The message loop also runs the main
// run loop (dispatch, timers, the main actor) and ticks the frame loop at up to 60 Hz while it is awake.
//
// Not here yet (human-checked items in docs/WINDOWS.md): the desktop-layer window behind the icons (WorkerW),
// the tray icon and menus, drag and drop, and the auxiliary windows.

enum WinApp {
    static func run(_ options: WinOptions, environment: [String: String]) {
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))   // per-monitor v2
        _ = CoInitializeEx(nil, DWORD(0x2))                                            // apartment threaded
        let folder = options.resolvedFolder(environment: environment)
        let stateDirectory = options.stateFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? StateStore.defaultDirectory(bundleID: "Deskterior")
        let window = DeskWindow(title: "Deskterior")
        do {
            try window.open(
                folder: folder, stateDirectory: stateDirectory, connect: options.connect,
                size: (options.width, options.height)
            )
        } catch {
            message("Deskterior could not start: \(error)")
            exit(1)
        }
        let deadline = options.quitAfter.map { FrameClock.now() + $0 }
        MessageLoop.run(ticker: window.ticker, deadline: deadline) { window.requestClose() }
        let shown = window.surface.framesShown
        window.close()
        if options.quitAfter != nil {
            print("window: \(shown) frame(s) shown, \(window.snapshots) snapshot(s)")
            exit(shown > 0 ? 0 : 2)
        }
    }

    static func message(_ text: String) {
        _ = text.withCString(encodedAs: UTF16.self) { t in
            "Deskterior".withCString(encodedAs: UTF16.self) { c in MessageBoxW(nil, t, c, UINT(0x10)) }
        }
    }
}

/// Ticks the frame loop from the message loop.
final class WinTicker: FrameTicker {
    var isPaused = true
    var lowPower = false
    var onTick: ((Double) -> Void)?
    func invalidate() { onTick = nil }

    var interval: Double { lowPower ? 1.0 / 30 : 1.0 / 60 }
}

enum MessageLoop {
    /// Pumps window messages, the main run loop and the ticker until `WM_QUIT`.
    static func run(ticker: WinTicker, deadline: Double? = nil, onDeadline: () -> Void = {}) {
        var msg = MSG()
        var nextTick = FrameClock.now()
        var deadline = deadline
        while true {
            if let d = deadline, FrameClock.now() >= d {
                deadline = nil
                onDeadline()
            }
            let now = FrameClock.now()
            let waitSeconds = ticker.isPaused ? 0.05 : max(0, nextTick - now)
            _ = MsgWaitForMultipleObjectsEx(0, nil, DWORD(waitSeconds * 1000), DWORD(0x04FF), DWORD(0x0004))
            while PeekMessageW(&msg, nil, 0, 0, UINT(0x0001)) {      // PM_REMOVE
                if msg.message == UINT(0x0012) { return }                        // WM_QUIT
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }
            _ = RunLoop.main.run(mode: .default, before: Date())
            let t = FrameClock.now()
            if !ticker.isPaused, t >= nextTick {
                nextTick = max(nextTick + ticker.interval, t - ticker.interval)
                ticker.onTick?(t)
            } else if ticker.isPaused {
                nextTick = t
            }
        }
    }
}

/// The desk's window.
final class DeskWindow: WinPlatform {
    let title: String
    let ticker = WinTicker()
    let surface = GDISurface()
    private(set) var hwnd: HWND?
    private var session: WinSession?
    private var dpi: UINT = 96
    private var lastClick: (time: Double, x: Int32, y: Int32, count: Int) = (0, 0, 0, 0)
    private var buttonDown = false

    static let className = "DeskteriorDesk"
    nonisolated(unsafe) static var registered = false

    init(title: String) {
        self.title = title
    }

    func open(folder: URL, stateDirectory: URL, connect: Bool, size: (Int, Int)) throws {
        try Self.register()
        let style = DWORD(0x00CF_0000)                                         // WS_OVERLAPPEDWINDOW
        let useDefault = Int32(bitPattern: 0x8000_0000)                        // CW_USEDEFAULT
        let h = Self.className.withCString(encodedAs: UTF16.self) { cls in
            title.withCString(encodedAs: UTF16.self) { t in
                CreateWindowExW(0, cls, t, style, useDefault, useDefault, Int32(size.0), Int32(size.1), nil, nil,
                                GetModuleHandleW(nil), nil)
            }
        }
        guard let h else { throw WinError.window(GetLastError()) }
        hwnd = h
        SetWindowLongPtrW(h, -21, LONG_PTR(Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())))   // GWLP_USERDATA
        surface.hwnd = h
        dpi = max(96, GetDpiForWindow(h))
        let (w, hgt) = clientSize()
        let session = try WinSession(
            grid: WinOptions.grid(width: max(w, 640), height: max(hgt, 400), scale: Double(dpi) / 96),
            folder: folder, stateDirectory: stateDirectory
        )
        session.platform = self
        session.host.attach(surface: surface, ticker: ticker)
        self.session = session
        session.start(connect: connect)
        ShowWindow(h, 5)                                                       // SW_SHOW
        UpdateWindow(h)
        session.host.loop.wake()
    }

    var snapshots: Int { session?.snapshots ?? 0 }

    func requestClose() {
        if let hwnd { PostMessageW(hwnd, UINT(0x0010), 0, 0) }                  // WM_CLOSE
    }

    func close() {
        session?.stop()
        session?.host.invalidate()
        session = nil
    }

    enum WinError: Error { case register(DWORD), window(DWORD) }

    private static func register() throws {
        guard !registered else { return }
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.style = UINT(0x0001 | 0x0002)                                      // CS_VREDRAW | CS_HREDRAW
        wc.lpfnWndProc = deskWindowProc
        wc.hInstance = GetModuleHandleW(nil)
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))   // IDC_ARROW
        let ok = className.withCString(encodedAs: UTF16.self) { cls -> Bool in
            wc.lpszClassName = cls
            return RegisterClassExW(&wc) != 0
        }
        guard ok else { throw WinError.register(GetLastError()) }
        registered = true
    }

    private func clientSize() -> (Int, Int) {
        var r = RECT()
        guard let hwnd, GetClientRect(hwnd, &r) else { return (0, 0) }
        return (Int(r.right - r.left), Int(r.bottom - r.top))
    }

    // MARK: Messages

    func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch message {
        case 0x0005:                                                           // WM_SIZE
            resized()
            return 0
        case 0x02E0:                                                           // WM_DPICHANGED
            dpi = UINT(wParam & 0xFFFF)
            if let r = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee, let hwnd {
                SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(0x0004 | 0x0010))
            }
            resized()
            return 0
        case 0x0014:                                                           // WM_ERASEBKGND
            return 1
        case 0x000F:                                                           // WM_PAINT
            var ps = PAINTSTRUCT()
            if let hwnd, let hdc = BeginPaint(hwnd, &ps) {
                surface.paint(hdc)
                EndPaint(hwnd, &ps)
            }
            return 0
        case 0x0200:                                                           // WM_MOUSEMOVE
            pointer(buttonDown ? .drag : .move, lParam)
            return 0
        case 0x0201:                                                           // WM_LBUTTONDOWN
            buttonDown = true
            if let hwnd { SetCapture(hwnd) }
            pointer(.down, lParam, clicks: countClick(lParam))
            return 0
        case 0x0202:                                                           // WM_LBUTTONUP
            buttonDown = false
            ReleaseCapture()
            pointer(.up, lParam, clicks: lastClick.count)
            return 0
        case 0x0204:                                                           // WM_RBUTTONDOWN
            pointer(.rightDown, lParam, clicks: 1)
            return 0
        case 0x020A:                                                           // WM_MOUSEWHEEL
            let delta = Float(Int16(truncatingIfNeeded: Int(wParam) >> 16)) / 120
            var p = POINT(x: LONG(Int16(truncatingIfNeeded: lParam)), y: LONG(Int16(truncatingIfNeeded: lParam >> 16)))
            if let hwnd { ScreenToClient(hwnd, &p) }
            send(InputEvent(.scroll, art: art(Int32(p.x), Int32(p.y)), mods: modifiers(), scroll: SIMD2(0, -delta * 8),
                            t: FrameClock.now()))
            return 0
        case 0x0215:                                                           // WM_CAPTURECHANGED
            if buttonDown {
                buttonDown = false
                session?.host.cancelInput()
            }
            return 0
        case 0x0100:                                                           // WM_KEYDOWN
            key(UInt32(wParam))
            return 0
        case 0x0010:                                                           // WM_CLOSE
            if let hwnd { DestroyWindow(hwnd) }
            return 0
        case 0x0002:                                                           // WM_DESTROY
            PostQuitMessage(0)
            return 0
        default:
            return nil
        }
    }

    private func resized() {
        guard let session else { return }
        let (w, h) = clientSize()
        guard w > 0, h > 0 else { return }                                      // minimised
        let grid = WinOptions.grid(width: w, height: h, scale: Double(dpi) / 96)
        guard grid != session.host.grid else { return }
        try? session.host.setGrid(grid)
        session.host.loop.renderOnce()
    }

    private func countClick(_ lParam: LPARAM) -> Int {
        let (x, y) = (Int32(Int16(truncatingIfNeeded: lParam)), Int32(Int16(truncatingIfNeeded: lParam >> 16)))
        let t = FrameClock.now()
        let interval = Double(GetDoubleClickTime()) / 1000
        let slopX = GetSystemMetrics(36), slopY = GetSystemMetrics(37)      // SM_CXDOUBLECLK, SM_CYDOUBLECLK
        if t - lastClick.time <= interval, abs(x - lastClick.x) <= slopX / 2, abs(y - lastClick.y) <= slopY / 2 {
            lastClick = (t, x, y, lastClick.count + 1)
        } else {
            lastClick = (t, x, y, 1)
        }
        return lastClick.count
    }

    private func pointer(_ kind: InputEvent.Kind, _ lParam: LPARAM, clicks: Int = 0) {
        let x = Int32(Int16(truncatingIfNeeded: lParam)), y = Int32(Int16(truncatingIfNeeded: lParam >> 16))
        send(InputEvent(kind, art: art(x, y), mods: modifiers(), clickCount: clicks, t: FrameClock.now()))
    }

    private func send(_ event: InputEvent) {
        session?.host.handle(event)
    }

    /// Client device px → canvas art coordinates (y down), as the Mac view converts its points.
    private func art(_ x: Int32, _ y: Int32) -> SIMD2<Float> {
        guard let grid = session?.host.grid else { return .zero }
        let backing = grid.display.backingScale
        return ArtSpace.canvasArtPoint(fromViewPoint: SIMD2(Double(x) / backing, Double(y) / backing), grid: grid)
    }

    /// Ctrl is the Mac's ⌘ (select more, menu keys), Alt its ⌥ (copy instead of move).
    private func modifiers() -> InputEvent.Modifiers {
        var m: InputEvent.Modifiers = []
        if GetKeyState(0x10) < 0 { m.insert(.shift) }
        if GetKeyState(0x11) < 0 { m.insert(.command) }
        if GetKeyState(0x12) < 0 { m.insert(.option) }
        return m
    }

    /// Keys the desk understands, from Windows virtual-key codes.
    private func key(_ vk: UInt32) {
        let ctrl = GetKeyState(0x11) < 0, shift = GetKeyState(0x10) < 0
        let command: KeyCommand? = switch vk {
        case 0x1B: .escape
        case 0x0D: .open
        case 0x20: .quickLook
        case 0x25: .move(dx: -1, dy: 0)
        case 0x27: .move(dx: 1, dy: 0)
        case 0x26: .move(dx: 0, dy: -1)
        case 0x28: .move(dx: 0, dy: 1)
        case 0x41 where ctrl: .selectAll                                       // Ctrl+A
        case 0x46 where ctrl: .find                                            // Ctrl+F
        case 0x5A where ctrl: shift ? .redo : .undo                            // Ctrl+Z, Ctrl+Shift+Z
        case 0x59 where ctrl: .redo                                            // Ctrl+Y
        default: nil
        }
        if let command { session?.host.handleKey(command) }
    }

    // MARK: WinPlatform

    func open(_ urls: [URL]) {
        for url in urls { Shell.open(url) }
    }

    func reveal(_ urls: [URL]) {
        for url in urls { Shell.reveal(url) }
    }
}

/// The C window procedure: finds the `DeskWindow` from the window's user data.
private let deskWindowProc: WNDPROC = { hwnd, message, wParam, lParam in
    guard let hwnd else { return 0 }
    let raw = GetWindowLongPtrW(hwnd, -21)
    if raw != 0, let window = UnsafeRawPointer(bitPattern: Int(raw)).map({
        Unmanaged<DeskWindow>.fromOpaque($0).takeUnretainedValue()
    }) {
        if let handled = MainActor.assumeIsolated({ window.handle(message, wParam, lParam) }) { return handled }
    }
    return DefWindowProcW(hwnd, message, wParam, lParam)
}

/// Shows the lit frame: `StretchDIBits` from a top-down BGRA copy, nearest neighbour, at `scale` with the crop.
final class GDISurface: PixelSurface {
    var hwnd: HWND?
    private var bgra: [UInt8] = []
    private var size = (w: 0, h: 0)
    private var scale = 1
    private var crop = (left: 0, top: 0)
    private(set) var framesShown = 0

    func present(lit: PixelBuffer, scale: Int, cropLeft: Int, cropTop: Int) -> Bool {
        guard let hwnd, !IsIconic(hwnd) else { return false }
        let n = lit.width * lit.height
        if bgra.count != n * 4 { bgra = [UInt8](repeating: 0, count: n * 4) }
        lit.withUnsafePixels { src in
            bgra.withUnsafeMutableBufferPointer { dst in
                for i in 0..<n {
                    let c = src[i]
                    dst[i * 4] = c.b
                    dst[i * 4 + 1] = c.g
                    dst[i * 4 + 2] = c.r
                    dst[i * 4 + 3] = 255
                }
            }
        }
        size = (lit.width, lit.height)
        self.scale = max(1, scale)
        crop = (cropLeft, cropTop)
        InvalidateRect(hwnd, nil, false)
        UpdateWindow(hwnd)
        framesShown += 1
        return true
    }

    func paint(_ hdc: HDC) {
        guard size.w > 0, size.h > 0 else { return }
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = LONG(size.w)
        info.bmiHeader.biHeight = -LONG(size.h)                                // top-down
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(0)                                // BI_RGB
        SetStretchBltMode(hdc, 3)                                              // COLORONCOLOR: nearest
        bgra.withUnsafeBytes { raw in
            _ = StretchDIBits(
                hdc, Int32(-crop.left), Int32(-crop.top), Int32(size.w * scale), Int32(size.h * scale),
                0, 0, Int32(size.w), Int32(size.h), raw.baseAddress, &info, UINT(0), DWORD(0x00CC_0020)  // SRCCOPY
            )
        }
    }
}
#endif
