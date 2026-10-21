import AppKit
import DeskCore
import DeskScene

/// VoiceOver for the desk (DESIGN §4.5, §8.3 item 19), tied into the windows: the desk and wall windows carry
/// labels, `DeskView`'s elements (built from the scene's `accessibilityItems()`) get custom actions besides Open —
/// Quick Look, Show in Finder, and Move to Monitor for a file that is hidden away (the memo clips' cards included) —
/// and VoiceOver is told when the desk's layout changes (after a model change, never per frame: an object put away or
/// brought back, a note added, edited or taken off; Errata 30, 31) and hears the pixel toasts it cannot read. The
/// picture frame gets Choose Photo… and Remove Photo, an image token Hang in Picture Frame, and the frame's value
/// ("No photo" / "Your photo") changing is a layout change too (Erratum 33).
final class DeskAccessibility {
    /// Called by `DeskView` after it rebuilds its elements.
    static var decorate: (([DeskAccessibilityElement]) -> Void)?

    private weak var view: DeskView?
    private let store: Store
    private var lastItems: [Shown] = []

    /// What VoiceOver has been told about an item: a note's label follows its text.
    private struct Shown: Equatable {
        var id: String
        var label: String
        // MARK: picture frame (0.4.0)
        /// The item's value (the picture frame's "No photo" / "Your photo").
        var value: String?
    }

    init(view: DeskView, store: Store) {
        self.view = view
        self.store = store
        Self.decorate = { [weak self] elements in self?.decorate(elements) }
        store.observe { [weak self] _, _ in self?.stateChanged() }
        lastItems = items()
    }

    func invalidate() {
        Self.decorate = nil
    }

    /// Says a toast aloud (the pixels are not readable).
    func announce(_ toast: ToastKey) {
        guard let view else { return }
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: toast.text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func items() -> [Shown] {
        view?.host?.scene.accessibilityItems().map { Shown(id: $0.id, label: $0.label, value: $0.value) } ?? []
    }

    /// The visible items or their labels changed: VoiceOver re-reads the children.
    private func stateChanged() {
        let now = items()
        guard now != lastItems, let view else { return }
        lastItems = now
        NSAccessibility.post(element: view, notification: .layoutChanged)
    }

    private func decorate(_ elements: [DeskAccessibilityElement]) {
        for e in elements {
            // MARK: picture frame (0.4.0): the frame's Choose Photo… and Remove Photo (Erratum 33).
            if e.item.id == "frame" {
                var actions = [action(.choosePhoto) { $0.onRequest?(.command(.choosePhoto)) }]
                if store.state.framePhoto != nil { actions.append(action(.removePhoto) { $0.onAction?(.removePhoto) }) }
                e.setAccessibilityCustomActions(actions)
                continue
            }
            guard let key = e.item.token else { continue }
            var actions = e.accessibilityCustomActions() ?? []
            actions.append(action(.quickLook) { $0.onAction?(.requestQuickLook([key])) })
            actions.append(action(.showInFinder) { $0.onAction?(.requestReveal([key])) })
            let s = store.state
            // MARK: picture frame (0.4.0): one image token hangs in the frame while the wall shelf is out.
            if s.tokens.meta(of: key).map({ FramePhoto.refusal(for: $0) == nil }) == true, s.isOut(.wallShelf) {
                actions.append(action(.hangInFrame) { $0.onRequest?(.command(.hangInFrame(key))) })
            }
            if let loc = s.tokens.location(of: key), !loc.isScreen {
                actions.append(action(.axMoveToMonitor) { [weak self] scene in
                    guard let self else { return }
                    let cell = ScreenGrid.standard.firstFree(self.store.state.tokens.occupiedCells)
                    scene.onAction?(.move([key], to: cell.location))
                })
            }
            e.setAccessibilityCustomActions(actions)
        }
    }

    private func action(_ name: L10nKey, _ body: @escaping (DeskScene) -> Void) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: tr(name)) { [weak self] in
            MainActor.assumeIsolated {
                guard let scene = self?.view?.host?.scene else { return }
                body(scene)
                self?.view?.host?.modelChanged()
            }
            return true
        }
    }
}
