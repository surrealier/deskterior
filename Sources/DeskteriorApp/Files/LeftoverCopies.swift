import AppKit
import DeskCore
import DeskFiles
import DeskScene

/// Leftovers of an interrupted drop-in copy in the mirrored folder (`PartialCopies`; Errata 25). Once the desk is
/// connected to its folder (so reading it never brings up the privacy prompt before ⏻), its top level is listed off the
/// main thread; leftovers are logged and, once per session, a toast points at Settings, which lists them with Show in
/// Finder and Move to Trash. Nothing here changes a file: the trash is the user's Settings button, through
/// `EffectRunner.trashLeftovers` and `FileOperator` (a menu intent, into the Trash, re-checked by identity).
final class LeftoverCopies {
    let folder: URL
    private let host: SceneHost
    /// The leftovers last found (empty until the first look).
    private(set) var found: [PartialCopies.Leftover] = []
    /// Settings follows the list.
    var onChange: (([PartialCopies.Leftover]) -> Void)?
    private var toasted = false
    private var looking = false
    /// Looks finished so far (tests).
    private(set) var looks = 0

    init(folder: URL, host: SceneHost) {
        self.folder = folder
        self.host = host
    }

    /// Lists the folder's top level for leftovers, off the main thread (a slow or network volume never stalls the
    /// desk), then logs them and, the first time any are found, raises the toast.
    func look() {
        guard !looking else { return }
        looking = true
        let folder = folder
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = PartialCopies.find(in: folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.looking = false
                    self.looks += 1
                    self.adopt(list)
                }
            }
        }
    }

    /// Takes the leftovers a look found: logs a new list, tells Settings, and raises the toast the first time.
    func adopt(_ list: [PartialCopies.Leftover]) {
        let changed = list != found
        found = list
        if changed {
            for l in list { Log.info("leftover copy (not removed; Settings can move it to the Trash): \(l.url.path)") }
            onChange?(list)
        }
        if !list.isEmpty, !toasted {
            toasted = true
            host.scene.toast(.leftoverCopies)
            host.modelChanged()
        }
    }

    /// Shows what the leftovers hold in Finder (a leftover's own folder when it is empty). Opening changes nothing.
    func showInFinder() {
        let urls = found.flatMap { $0.contents.isEmpty ? [$0.url] : $0.contents }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
