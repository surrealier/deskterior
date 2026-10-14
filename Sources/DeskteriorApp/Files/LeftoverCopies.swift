import AppKit
import DeskCore
import DeskFiles
import DeskScene

/// Leftovers of an interrupted drop-in copy in the mirrored folder (`PartialCopies`; Errata 25). Once the mirror has
/// read the folder (its first snapshot, so this never brings up the privacy prompt before ⏻), its top level is listed
/// off the main thread; leftovers are logged and, once per session, a toast points at Settings, which lists them with Show in
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
    /// A look was asked for while one ran (after a trash): it runs once that one is in.
    private var lookAgain = false
    /// Looks finished so far (tests).
    private(set) var looks = 0
    /// Lists the leftovers in a folder; runs off the main thread (tests stand in to see where it runs).
    var find: @Sendable (URL) -> [PartialCopies.Leftover] = PartialCopies.find(in:)

    init(folder: URL, host: SceneHost) {
        self.folder = folder
        self.host = host
    }

    /// Lists the folder's top level for leftovers, off the main thread (a slow or network volume never stalls the
    /// desk), then logs them and, the first time any are found, raises the toast. One look runs at a time; one asked
    /// for meanwhile follows it, so a look after a trash never ends on a list read before it.
    func look() {
        guard !looking else {
            lookAgain = true
            return
        }
        looking = true
        let folder = folder, find = find
        // At the mirror's QoS: a main-queue block sent from a utility thread was seen waiting minutes behind a busy
        // main thread (the whole test suite).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = find(folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.looking = false
                    self.looks += 1
                    self.adopt(list)
                    if self.lookAgain {
                        self.lookAgain = false
                        self.look()
                    }
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

extension SettingsModel {
    /// Settings ▸ Leftover copies follows `leftovers`, a session's (after a folder switch: the new folder's, none
    /// until its look is in), and drops the note the last Move to Trash left.
    func follow(_ leftovers: LeftoverCopies) {
        self.leftovers = leftovers.found.count
        leftoverNote = nil
    }
}
