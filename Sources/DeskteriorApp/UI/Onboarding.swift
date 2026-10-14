import AppKit
import DeskCore
import Observation
import SwiftUI

/// First-run notes in English or Korean (DESIGN §3.1, §4.10, §6): the welcome card — where the files are, how hiding
/// works, that files change only on request, ⏻ to connect, Find Item… — with the cover prompt when more than one
/// display is connected (preselected: Cover), and the one-time note to move a translocated app to /Applications.
/// Answers are kept in the settings (`onboardingStep`, `coverOtherDisplays`, `translocationNoteShown`).
final class OnboardingController {
    private var welcome: NSWindow?
    private var note: NSWindow?

    /// The welcome card; `done` gets the cover answer (nil when it was not asked).
    func showWelcome(askCover: Bool, done: @escaping (Bool?) -> Void) {
        let model = WelcomeModel(askCover: askCover)
        model.finish = { [weak self] in
            self?.welcome?.orderOut(nil)
            self?.welcome = nil
            done(askCover ? model.cover : nil)
        }
        let w = AppWindow.make(title: tr(.welcomeTitle), view: WelcomeView(model: model), closable: false)
        welcome = w
        AppWindow.present(w)
    }

    /// The one-time App Translocation note.
    func showTranslocationNote(done: @escaping () -> Void) {
        let w = AppWindow.make(title: tr(.translocationTitle), view: NoteView(title: tr(.translocationTitle),
                                                                              body: tr(.translocationBody)) { [weak self] in
            self?.note?.orderOut(nil)
            self?.note = nil
            done()
        })
        note = w
        AppWindow.present(w)
    }

    /// The windows on show, by name (development screenshots).
    var shownWindows: [(name: String, window: NSWindow)] {
        [("onboarding", welcome), ("translocation", note)].compactMap { n, w in w.map { (n, $0) } }
    }
}

@Observable
final class WelcomeModel {
    let askCover: Bool
    /// Preselected: Cover (DESIGN §4.8 `coverOtherDisplays`).
    var cover = true
    @ObservationIgnored var finish: () -> Void = {}

    init(askCover: Bool) {
        self.askCover = askCover
    }
}

struct WelcomeView: View {
    @Bindable var model: WelcomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let icon = AboutView.icon() {
                    Image(decorative: icon, scale: 1).interpolation(.none).resizable().frame(width: 64, height: 64)
                }
                Text(tr(.welcomeTitle)).font(.title2.bold())
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(tr(.welcomeMonitor), systemImage: "display")
                Label(tr(.welcomeHide), systemImage: "archivebox")
                Label(tr(.welcomeSafe), systemImage: "lock.shield")
                Label(tr(.welcomeConnect), systemImage: "power")
                Label(tr(.welcomeFind), systemImage: "magnifyingglass")
            }
            .fixedSize(horizontal: false, vertical: true)
            if model.askCover {
                Divider()
                Text(tr(.welcomeDisplays)).font(.callout)
                Toggle(tr(.coverDisplays), isOn: $model.cover)
            }
            HStack {
                Spacer()
                Button(tr(.start)) { model.finish() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

/// A short note with one button.
struct NoteView: View {
    var title: String
    var body_: String
    var done: () -> Void

    init(title: String, body: String, done: @escaping () -> Void) {
        self.title = title
        body_ = body
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(body_).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr(.ok), action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
