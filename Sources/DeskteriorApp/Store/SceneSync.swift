import DeskCore
import DeskScene
import Foundation

/// Keeps a scene in step with the `Store` (DESIGN §4.3): every committed state is applied to the scene (and the
/// desk menu learns the undo labels), and real icons follow the files. A token whose request changed — new, renamed
/// (new URL), re-keyed by a safe-save (new key; the old key's icon is dropped), modified (new mtime/size) — is
/// asked of `IconProvider`, tokens on the current page first; a `.stale` answer (the file moved while rendering)
/// is asked again at the token's current URL. Positions need no events: the scene re-reads them from the state.
final class SceneSync {
    let host: SceneHost
    private unowned let store: Store
    let icons: IconProvider?
    /// Pause Desk, for the desk menu.
    var isPaused: () -> Bool = { false }
    /// What was last asked for each token.
    private var requested: [TokenKey: IconProvider.Request] = [:]
    /// Icons delivered so far (demo idle checks).
    private(set) var iconCount = 0
    private(set) var lastIconAt: Date?

    init(host: SceneHost, store: Store, icons: IconProvider?) {
        self.host = host
        self.store = store
        self.icons = icons
        icons?.onIcon = { [weak self] key, result in self?.iconArrived(key, result) }
    }

    /// Pushes the current state and follows every change from now on.
    func start() {
        store.observe { [weak self] new, _ in self?.push(new) }
        push(store.state)
    }

    /// Refreshes the desk menu's labels (after an undo or a pause toggle).
    func refreshMenuContext() {
        host.scene.menuContext = MenuSpec.Context(paused: isPaused(), undo: store.undoLabel, redo: store.redoLabel)
    }

    private func push(_ s: DeskState) {
        refreshMenuContext()
        host.scene.apply(s)
        requestIcons(s)
        host.modelChanged()
    }

    private func requestIcons(_ s: DeskState) {
        let live = Set(s.tokens.records.keys)
        if requested.keys.contains(where: { !live.contains($0) }) {
            requested = requested.filter { live.contains($0.key) }
            host.scene.pruneIcons(keeping: live)
        }
        guard let icons, s.access == .connected else { return }
        var batch: [IconProvider.Request] = []
        for key in s.tokens.sortedKeys {
            guard let meta = s.tokens.meta(of: key), let url = s.url(of: key) else { continue }
            let r = IconProvider.Request(key: key, url: url, meta: meta)
            if requested[key] != r {
                requested[key] = r
                batch.append(r)
            }
        }
        guard !batch.isEmpty else { return }
        let page = s.monitor.page
        let visible = Set(s.tokens.keys { $0.cell?.page == page })
        icons.request(batch, visible: visible)
    }

    private func iconArrived(_ key: TokenKey, _ result: IconProvider.Result) {
        lastIconAt = Date()
        switch result {
        case let .pixels(icon, _):
            iconCount += 1
            host.scene.setIcon(key, icon)
            host.modelChanged()
        case .kindOnly:
            host.scene.setIcon(key, nil)
        case .stale:
            requested[key] = nil
            requestIcons(store.state)
        }
    }
}
