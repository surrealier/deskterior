import AppKit
import DeskCore
import DeskScene

/// VoiceOver for the desk (DESIGN §4.5, §8.3 item 19), tied into the windows: the desk and wall windows carry
/// labels, `DeskView`'s elements (built from the scene's `accessibilityItems()`) get custom actions besides Open —
/// Quick Look, Show in Finder, and Move to Monitor for a file that is hidden away — and VoiceOver is told when the
/// desk's layout changes (after a model change, never per frame) and hears the pixel toasts it cannot read.
final class DeskAccessibility {
    /// Called by `DeskView` after it rebuilds its elements.
    static var decorate: (([DeskAccessibilityElement]) -> Void)?

    private weak var view: DeskView?
    private let store: Store
    private var lastIDs: [String] = []

    init(view: DeskView, store: Store) {
        self.view = view
        self.store = store
        Self.decorate = { [weak self] elements in self?.decorate(elements) }
        store.observe { [weak self] _, _ in self?.stateChanged() }
        lastIDs = ids()
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

    private func ids() -> [String] {
        view?.host?.scene.accessibilityItems().map(\.id) ?? []
    }

    /// The visible items changed: VoiceOver re-reads the children.
    private func stateChanged() {
        let now = ids()
        guard now != lastIDs, let view else { return }
        lastIDs = now
        NSAccessibility.post(element: view, notification: .layoutChanged)
    }

    private func decorate(_ elements: [DeskAccessibilityElement]) {
        for e in elements {
            guard let key = e.item.token else { continue }
            var actions = e.accessibilityCustomActions() ?? []
            actions.append(action(.quickLook) { $0.onAction?(.requestQuickLook([key])) })
            actions.append(action(.showInFinder) { $0.onAction?(.requestReveal([key])) })
            let s = store.state
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
