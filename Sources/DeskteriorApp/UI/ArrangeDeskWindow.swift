import AppKit
import DeskCore
import Observation
import SwiftUI

/// Arrange Desk… (소품 정리, Erratum 30): everything that can be put away, grouped Storage / Desk / Partition / Wall as
/// `StowCatalog` lists it, each with an "On the Desk" toggle (off puts it away, on brings it back), how many files it
/// holds, and what putting it away does to them ("Putting it away takes 3 files out to the monitor."). The
/// partition's add-ons come and go with it, so their rows rest while it is away. Plain SwiftUI toggles: this is also
/// the VoiceOver path to objects that have no pixels to click once they are away. Nothing asks first (⌘Z undoes).
final class ArrangeDeskWindowController: NSObject, NSWindowDelegate {
    let model: ArrangeDeskModel
    private var window: NSWindow?
    private var observer: Int?
    private unowned let store: Store

    init(store: Store) {
        self.store = store
        model = ArrangeDeskModel(state: store.state)
        super.init()
        model.dispatch = { [weak self] in self?.store.dispatch($0) }
    }

    func show() {
        if window == nil {
            let w = AppWindow.make(title: tr(.arrangeTitle), view: ArrangeDeskView(model: model))
            w.delegate = self
            window = w
        }
        if observer == nil {
            observer = store.observe { [weak self] new, _ in self?.model.state = new }
        }
        model.state = store.state
        languageChanged()
        if let window { AppWindow.present(window) }
    }

    /// The window while it is on screen (development screenshots, `--show arrange`).
    var shownWindow: NSWindow? { window?.isVisible == true ? window : nil }

    /// Shows the window's text in the current language (Settings ▸ Language changed).
    func languageChanged() {
        window?.title = tr(.arrangeTitle)
        model.language = L10n.language
    }

    /// Closes the window for good (its store is going away: another folder is mirrored).
    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let observer { store.removeObserver(observer) }
        observer = nil
    }
}

/// The Arrange Desk window's rows, read from the model.
@Observable
final class ArrangeDeskModel {
    /// One object's row.
    struct Row: Equatable {
        var id: StowID
        var title: String
        /// Files in its hiding places (its add-ons' included); nil for an object that has none.
        var inside: Int?
        /// The toggle: the object's own put-away flag.
        var isOn: Bool
        /// False for an add-on while the partition is away (it comes back with it).
        var isEnabled: Bool
        /// "Putting it away takes 3 files out to the monitor." or "Comes back with the partition."
        var caption: String?
    }

    var state: DeskState
    /// The language the window speaks (the view re-renders when it changes).
    var language = L10n.language
    @ObservationIgnored var dispatch: (DeskAction) -> Void = { _ in }

    init(state: DeskState) {
        self.state = state
    }

    /// The rows of `group`, in `StowCatalog` order.
    func rows(_ group: StowSpec.Group) -> [Row] {
        StowID.allCases.filter { StowCatalog.spec($0).group == group }.map { Self.row($0, in: state) }
    }

    /// The toggle was flipped: off puts the object away, on brings it back.
    func set(_ id: StowID, on: Bool) {
        dispatch(on ? .bringBack(id) : .putAway(id))
    }

    func bringEverythingBack() {
        dispatch(.bringBackAll)
    }

    var anythingAway: Bool { !state.stowed.isEmpty }

    /// `id`'s row in `language` (default: the app's).
    static func row(_ id: StowID, in s: DeskState, language: Language? = nil) -> Row {
        let spec = StowCatalog.spec(id)
        let holds = ([id] + StowCatalog.children(of: id)).contains { !StowCatalog.spec($0).containers.isEmpty }
        let files = s.tokensInside(id).count
        let parentAway = spec.parent.map { !s.isOut($0) } ?? false
        // An add-on keeps its own flag while the partition is away: one put away itself stays away when it comes back.
        let caption: String? = if parentAway {
            L10n.text(s.stowed.contains(id) ? .staysAwayWithPartition : .withPartition, language)
        } else if s.isOut(id), files > 0 {
            L10n.format(.takesOut, [files], language)
        } else {
            nil
        }
        return Row(id: id, title: L10n.tr(spec.title, language), inside: holds ? files : nil,
                   isOn: !s.stowed.contains(id), isEnabled: !parentAway, caption: caption)
    }

    static func title(_ group: StowSpec.Group, language: Language? = nil) -> String {
        let key: L10nKey = switch group {
        case .storage: .groupStorage
        case .desk: .groupDesk
        case .partition: .groupPartition
        case .wall: .groupWall
        }
        return L10n.text(key, language)
    }
}

struct ArrangeDeskView: View {
    @Bindable var model: ArrangeDeskModel

    var body: some View {
        let _ = model.language
        VStack(spacing: 0) {
            Form {
                ForEach(StowSpec.Group.allCases, id: \.self) { group in
                    Section(ArrangeDeskModel.title(group)) {
                        ForEach(model.rows(group), id: \.id) { row in
                            ArrangeDeskRow(row: row) { model.set(row.id, on: $0) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(alignment: .center, spacing: 12) {
                Text(tr(.arrangeFooter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(tr(.bringBackAll)) { model.bringEverythingBack() }
                    .disabled(!model.anythingAway)
            }
            .padding(12)
        }
        .frame(width: 460, height: 600)
    }
}

/// One object: its name, how many files it holds and its caption, then its "On the Desk" switch.
struct ArrangeDeskRow: View {
    let row: ArrangeDeskModel.Row
    let set: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                if let inside = row.inside {
                    Text(L10n.format(.inside, [inside])).font(.caption).foregroundStyle(.secondary)
                }
                if let caption = row.caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            // "On the Desk" is the switch's name for VoiceOver ("Cabinet, On the Desk"); the row shows the object's.
            Toggle(tr(.onTheDesk), isOn: Binding(get: { row.isOn }, set: { set($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(tr(.onTheDesk))
                .accessibilityLabel("\(row.title), \(tr(.onTheDesk))")
        }
        .disabled(!row.isEnabled)
    }
}
