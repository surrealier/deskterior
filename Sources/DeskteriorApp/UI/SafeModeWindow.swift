import AppKit
import DeskCore
import DeskFiles
import Observation
import SwiftUI

/// Safe Mode (DESIGN §4.11, §8.3 item 16): holding ⌥ at launch (or `--safe-mode`) shows this small window before the
/// desk starts. Start Normally starts it; Reset Layout… keeps the saved layout as a backup in the state folder and
/// starts from a fresh desk (every file back on the monitor); Quit quits. No file is ever deleted.
final class SafeModeController {
    private var window: NSWindow?
    private let model: SafeModeModel

    init(stateDirectory: URL, mirrored: URL?, start: @escaping () -> Void) {
        model = SafeModeModel(stateDirectory: stateDirectory, mirrored: mirrored)
        model.start = { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
            start()
        }
    }

    func show() {
        let w = AppWindow.make(title: tr(.safeModeTitle), view: SafeModeView(model: model), closable: false)
        window = w
        AppWindow.present(w)
    }

    var shownWindow: NSWindow? { window }
}

@Observable
final class SafeModeModel {
    let stateDirectory: URL
    let mirrored: URL?
    var confirming = false
    var message: String?
    @ObservationIgnored var start: () -> Void = {}

    init(stateDirectory: URL, mirrored: URL?) {
        self.stateDirectory = stateDirectory
        self.mirrored = mirrored
    }

    func reset() {
        do {
            let store = try StateStore(directory: stateDirectory, mirrored: mirrored)
            if let kept = try store.resetLayout() {
                message = L10n.format(.resetDone, [kept.lastPathComponent])
                Log.info("safe mode: layout reset, kept \(kept.path)")
            } else {
                message = tr(.resetNothing)
            }
        } catch {
            message = L10n.format(.resetFailed, ["\(error)"])
        }
        confirming = false
    }
}

struct SafeModeView: View {
    @Bindable var model: SafeModeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr(.safeModeTitle)).font(.headline)
            Text(tr(.safeModeBody)).fixedSize(horizontal: false, vertical: true)
            if model.confirming {
                Text(tr(.resetConfirm)).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(tr(.cancel)) { model.confirming = false }
                    Button(tr(.reset)) { model.reset() }
                }
            } else if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            HStack {
                Button(tr(.quitButton)) { NSApp.terminate(nil) }
                Button(tr(.openStateFolder)) { NSWorkspace.shared.open(model.stateDirectory) }
                Spacer()
                Button(tr(.resetLayout)) { model.confirming = true }.disabled(model.confirming)
                Button(tr(.startNormally)) { model.start() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
