import AppKit
import DeskCore
@_spi(IntentMinting) import DeskFiles
import DeskScene
import QuickLookUI

/// Runs the reducer's effects (DESIGN §3.5, §4.3) on the main actor. Opening, revealing, Quick Look and copying
/// hand files to the system and never change them; the scene gets its animations, toasts and wakeups; the
/// mirror connects on ⏻. In dry runs (`--demo`, `--headless`) none of those reaches the system: they are only
/// recorded.
///
/// File changes (Move to Trash, Empty Wastebasket, drop-in imports, their undo, Eject) go to `FileOperator` through
/// `FileActions`, each with one `ExplicitIntent` minted here — the only place intents are minted (Errata 14) —
/// right before its one call: a trash with the origin it was requested from (`withOrigin`: a token menu by default,
/// the Inventory, the Dock Trash), or `sheetConfirm` once Empty Wastebasket's sheet was confirmed; an import with
/// `drop`, an undo with `undo` (its record from the journal, redeemed on the operator that issued it), an eject from
/// a menu. Demos run them for real, on the fixture with the FakeTrash (`FileActionScope`).
final class EffectRunner {
    let host: SceneHost
    weak var mirror: MirrorController?
    /// The mirrored folder (Choose Folder… must pick this one).
    let folder: URL
    let dryRun: Bool
    /// Effects that touched files so far, newest last (`open`, `reveal`, `quickLook`, `copy`, `trash`,
    /// `emptyWastebasket`, `import`, `undo`, `eject`; demo expectations).
    private(set) var fileLog: [String] = []
    /// Called after Choose Folder… granted access (the store dispatches `.accessGranted`).
    var onAccessGranted: (() -> Void)?
    // MARK: files
    /// The session's file operator and undo records (nil: no file can change; requests only toast).
    var files: FileActions?
    /// Asks before Empty Wastebasket… (the app's sheet; demos answer for themselves); `done(true)` goes ahead.
    var confirm: (ConfirmKind, Int, @escaping (Bool) -> Void) -> Void = { kind, count, done in
        EmptyBasketSheet.present(kind, count: count, done: done)
    }
    /// The last confirmation asked for (`emptyWastebasket:<count>`; demo expectations).
    private(set) var lastSheet: String?
    /// Where the request being dispatched came from (`withOrigin`); a menu item unless said otherwise.
    private(set) var requestOrigin: ExplicitIntent.Origin = .menuItem

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
        case .trash, .importFiles, .eject, .undoFiles:
            runFileEffect(effect)
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

    /// Dispatches inside `body` count as requested from `origin` (the Inventory, the Dock Trash).
    func withOrigin(_ origin: ExplicitIntent.Origin, _ body: () -> Void) {
        let outer = requestOrigin
        requestOrigin = origin
        defer { requestOrigin = outer }
        body()
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

// MARK: - File actions (the only place an ExplicitIntent is minted)

extension EffectRunner {
    /// One file effect: refused with a toast when no operator runs or the origin does not fit; Empty Wastebasket
    /// asks first. Every intent is minted right before the one operator call that spends it.
    fileprivate func runFileEffect(_ effect: Effect) {
        guard let files else {
            toast(.fileFailed)
            return
        }
        switch effect {
        case let .trash(urls, keys, confirm?):
            if case let .emptyWastebasket(names, more) = confirm { lastSheet = "emptyWastebasket:\(names.count + more)" }
            self.confirm(confirm, urls.count) { [weak self] go in
                guard go, let self, let origin = ExplicitIntent.Origin.minted(for: effect, requestedVia: .sheetConfirm,
                                                                               confirmed: true) else { return }
                record("emptyWastebasket")
                let intent = ExplicitIntent(origin: origin)
                files.run({ await $0.trash(urls, expecting: keys, intent) }) {
                    FileReport(trash: $0, keys: keys, kind: .emptyWastebasket, undo: $1)
                }
            }
        case let .trash(urls, keys, nil):
            guard let origin = mintable(effect) else { return }
            record("trash")
            let intent = ExplicitIntent(origin: origin)
            files.run({ await $0.trash(urls, expecting: keys, intent) }) {
                FileReport(trash: $0, keys: keys, kind: .trash, undo: $1)
            }
        case let .importFiles(urls, op, _):
            guard let origin = mintable(effect) else { return }
            record("import")
            let intent = ExplicitIntent(origin: origin)
            files.run({ await $0.importItems(urls, op: op, intent) }) { FileReport(import: $0, undo: $1) }
        case let .undoFiles(ref):
            guard let origin = mintable(effect) else { return }
            guard let undo = files.take(ref) else {
                toast(.fileFailed)
                return
            }
            record("undo")
            let intent = ExplicitIntent(origin: origin)
            files.run({ await $0.undo(undo, intent) }) { result, _ in FileReport(undo: result) }
        case let .eject(path):
            guard let origin = mintable(effect) else { return }
            record("eject")
            let intent = ExplicitIntent(origin: origin)
            let volume = URL(fileURLWithPath: path, isDirectory: true)
            files.runEject { await $0.eject(volume, intent) }
        default:
            break
        }
    }

    /// The origin to mint for `effect`, or nil (with a toast) when the request's origin does not fit it.
    private func mintable(_ effect: Effect) -> ExplicitIntent.Origin? {
        guard let origin = ExplicitIntent.Origin.minted(for: effect, requestedVia: requestOrigin) else {
            FileHandle.standardError.write(Data("Deskterior: no intent for \(effect) from \(requestOrigin)\n".utf8))
            toast(.fileFailed)
            return nil
        }
        return origin
    }

    private func toast(_ key: ToastKey) {
        host.scene.toast(key)
        host.modelChanged()
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
