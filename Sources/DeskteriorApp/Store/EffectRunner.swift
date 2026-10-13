import AppKit
import DeskCore
import DeskFiles
import DeskScene
import QuickLookUI

/// Runs the reducer's effects (DESIGN §3.5, §4.3) on the main actor. Opening, revealing, Quick Look and copying
/// hand files to the system and never change them; the scene gets its animations, toasts and wakeups; the
/// mirror connects on ⏻. File mutations (Move to Trash, Empty Wastebasket, Eject, drop-in imports) arrive with
/// `FileOperator` in M11: until then they only show the "Not available yet" toast, and no `ExplicitIntent` is
/// minted. In dry runs (`--demo`, `--headless`) nothing reaches the system at all: effects are only recorded.
final class EffectRunner {
    let host: SceneHost
    weak var mirror: MirrorController?
    /// The mirrored folder (Choose Folder… must pick this one).
    let folder: URL
    let dryRun: Bool
    /// File-touching effects so far, newest last (`open`, `reveal`, `quickLook`, `copy`; demo expectations).
    private(set) var fileLog: [String] = []
    /// Called after Choose Folder… granted access (the store dispatches `.accessGranted`).
    var onAccessGranted: (() -> Void)?

    init(host: SceneHost, folder: URL, dryRun: Bool) {
        self.host = host
        self.folder = folder
        self.dryRun = dryRun
    }

    func run(_ effect: Effect) {
        switch effect {
        case let .open(urls):
            record("open")
            if !dryRun { for url in urls { NSWorkspace.shared.open(url) } }
        case let .reveal(urls):
            record("reveal")
            if !dryRun { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        case let .quickLook(urls):
            record("quickLook")
            if !dryRun { QuickLookSource.shared.show(urls, from: host) }
        case let .copy(urls):
            record("copy")
            if !dryRun {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(urls.map { $0 as NSURL })
            }
        case .trash, .importFiles, .eject:
            // TODO(M11): FileOperator with an ExplicitIntent minted here, and only here.
            host.scene.toast(.notYetAvailable)
            host.modelChanged()
        case .connectDesktop:
            mirror?.connect()
        case let .play(id, target):
            host.scene.play(id, target)
            host.modelChanged()
        case let .toast(key):
            host.scene.toast(key)
            host.modelChanged()
        case .persist:
            break
        case .wakeLoop:
            host.modelChanged()
        case .openPrivacySettings:
            record("openPrivacySettings")
            if !dryRun, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                NSWorkspace.shared.open(url)
            }
        case .chooseFolder:
            record("chooseFolder")
            if !dryRun { chooseFolder() }
        }
    }

    private func record(_ name: String) {
        fileLog.append(name)
        if fileLog.count > 50 { fileLog.removeFirst(fileLog.count - 50) }
    }

    /// Choose Folder… on the NO SIGNAL card: picking the mirrored folder in the open panel grants access through
    /// user intent (TCC), then the mirror reconnects.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Use Folder"
        panel.message = "Choose your Desktop folder so Deskterior can show it."
        NSApp.activate()
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        if DesktopLocator.canonicalPath(picked) == DesktopLocator.canonicalPath(folder) {
            onAccessGranted?()
        } else {
            host.scene.toast(.accessDenied)
            host.modelChanged()
        }
    }
}

/// The Quick Look panel's data source (DESIGN §3.5): `DeskView` takes control of the panel in the responder
/// chain and hands it this source.
final class QuickLookSource: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookSource()
    private(set) var urls: [URL] = []

    func show(_ urls: [URL], from host: SceneHost) {
        self.urls = urls
        NSApp.activate()
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}
