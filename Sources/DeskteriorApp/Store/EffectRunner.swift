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
/// File changes (Move to Trash, Empty Wastebasket, drop-in imports and aliases, their undo, Eject) go to
/// `FileOperator` through `FileActions`, each with one `ExplicitIntent` minted here — the only place intents are
/// minted (Errata 14) — right before its one call, from the gesture the request came from (`withOrigin`; a request dispatched with no
/// gesture named mints nothing and only toasts): a trash with the origin it was requested from (a menu, the
/// Inventory, the Dock Trash), or `sheetConfirm` once Empty Wastebasket's sheet, asked for from a menu, was
/// confirmed; an import with `drop`; an undo with `undo` from ⌘Z or a menu's Undo (its record from the journal,
/// redeemed on the operator that issued it); an eject from a menu. Demos run them for real, on the fixture with the
/// FakeTrash (`FileActionScope`).
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
    /// The gesture the request being dispatched came from (`withOrigin`); nil when none was named, and then no file
    /// changes.
    private(set) var requestOrigin: ExplicitIntent.Origin?

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
        case let .cancelFiles(ref):
            files?.cancel(ref)
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

    /// Dispatches inside `body` count as requested from `origin`: a menu, the Inventory, the Dock Trash, a drop, ⌘Z.
    /// Only gesture handlers call this (the file-safety lint holds the list).
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
        panel.prompt = tr(.panelUseFolder)
        panel.message = tr(.panelChooseDesktop)
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
            // The sheet is asked for from a menu; its confirmation is the gesture that mints.
            let requested = requestOrigin
            guard mintable(effect, confirmed: true) != nil else { return }
            self.confirm(confirm, urls.count) { [weak self] go in
                guard go, let self, let origin = ExplicitIntent.Origin.minted(for: effect, requestedVia: requested,
                                                                               confirmed: true) else { return }
                record("emptyWastebasket")
                let intent = ExplicitIntent(origin: origin)
                files.run(.emptyWastebasket, { op, _ in await op.trash(urls, expecting: keys, intent) }) {
                    FileReport(trash: $0, keys: keys, kind: .emptyWastebasket, undo: $1)
                }
            }
        case let .trash(urls, keys, nil):
            guard let origin = mintable(effect) else { return }
            record("trash")
            let intent = ExplicitIntent(origin: origin)
            files.run(.trash, { op, _ in await op.trash(urls, expecting: keys, intent) }) {
                FileReport(trash: $0, keys: keys, kind: .trash, undo: $1)
            }
        case let .importFiles(urls, ops, _):
            guard let origin = mintable(effect) else { return }
            record("import")
            let intent = ExplicitIntent(origin: origin)
            // Each item with its own op (Erratum 29: an app dropped beside documents becomes an alias).
            let headline = ImportOp.headline(ops)
            files.run(.importItems, op: headline, { await $0.importItems(urls, ops: ops, intent, progress: $1) }) {
                FileReport(import: $0, undo: $1, ops: ops)
            }
        case let .undoFiles(ref):
            guard let origin = mintable(effect) else {
                files.undoNotRun(ref)
                return
            }
            record("undo")
            let intent = ExplicitIntent(origin: origin)
            files.runUndo(ref) { await $0.undo($1, intent) }
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

    // MARK: harden

    /// Settings ▸ Leftover copies ▸ Move to Trash (Errata 25): the leftovers of an interrupted copy go to the trash,
    /// each only while it is still the folder that was found (`FileOperator.trash` re-checks its identity). Only a
    /// button the user pressed may ask (`withOrigin(.menuItem)` in the app delegate); nothing is journaled, and the
    /// Trash's Put Back returns them. `done` hears the result (nil: nothing ran).
    func trashLeftovers(_ items: [PartialCopies.Leftover], done: @escaping (FileResult?) -> Void) {
        guard let files, !items.isEmpty, requestOrigin == .menuItem else {
            if !items.isEmpty { FileHandle.standardError.write(Data("Deskterior: no intent for leftovers\n".utf8)) }
            return done(nil)
        }
        record("trash")
        let intent = ExplicitIntent(origin: .menuItem)
        let urls = items.map(\.url), keys = items.map(\.key)
        files.runUnjournaled({ await $0.trash(urls, expecting: keys, intent) }, done: done)
    }

    /// The origin to mint for `effect`, or nil (with a toast) when the request's gesture does not fit it.
    private func mintable(_ effect: Effect, confirmed: Bool = false) -> ExplicitIntent.Origin? {
        guard let origin = ExplicitIntent.Origin.minted(for: effect, requestedVia: requestOrigin, confirmed: confirmed) else {
            let from = requestOrigin.map(\.rawValue) ?? "no gesture"
            FileHandle.standardError.write(Data("Deskterior: no intent for \(effect) from \(from)\n".utf8))
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
        panel.level = AppWindow.level  // M12: above the desk while Peek Desk floats it.
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
        // MARK: harden: the panel may ask for an index of an earlier, longer list.
        MainActor.assumeIsolated { () -> NSURL? in urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}
