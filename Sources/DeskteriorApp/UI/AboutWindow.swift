import AppKit
import DeskCore
import DeskPixels
import SwiftUI

/// About & Credits (DESIGN §6 item 10–11): the pixel app icon, the version, the safety promise, and the credits — an
/// independent project inspired by Terkel Gjervig's *Desktop Cleaning*, not affiliated with or endorsed by him and
/// using none of its code, name, art or branding; Galmuri9 (Lee Minseo, SIL OFL 1.1); the Apollo palette
/// (AdamCYounis); MIT-licensed code.
struct AboutView: View {
    var version: String
    var close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let icon = Self.icon() {
                Image(decorative: icon, scale: 1).interpolation(.none).resizable().frame(width: 96, height: 96)
            }
            Text("Deskterior").font(.title2.bold())
            Text(L10n.format(.version, [version])).font(.callout).foregroundStyle(.secondary)
            Text(tr(.aboutTagline))
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(tr(.aboutSafety))
                Text(tr(.aboutInspired))
                Text(tr(.aboutIndependent)).foregroundStyle(.secondary)
                Text(tr(.aboutFont))
                Text(tr(.aboutPalette))
                Text(tr(.aboutLicense))
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            Button(tr(.close), action: close).keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 420)
    }

    /// The 32-px master icon art, nearest-scaled ×3 so it stays crisp.
    static func icon() -> CGImage? {
        AppIconArt.master.render().scaledNearest(3).makeCGImage()
    }
}

/// Keeps one About window.
final class AboutWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = AppWindow.make(title: tr(.aboutTitle), view: AboutView(version: AppVersion.current) { [weak self] in
                self?.window?.performClose(nil)
            })
            window = w
        }
        if let window { AppWindow.present(window) }
    }

    var shownWindow: NSWindow? { window?.isVisible == true ? window : nil }
}
