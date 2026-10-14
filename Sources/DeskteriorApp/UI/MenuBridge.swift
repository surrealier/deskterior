import AppKit
import DeskCore

/// Turns a `MenuSpec` into an `NSMenu` (DESIGN §4.9): titles, separators, submenus, check marks and disabled
/// items; choosing an item calls `perform` with its `MenuCommand`. No key equivalents are set (there are no
/// destructive ones; the desk's keys are handled by `DeskView`). Keep the bridge alive while its menu is open
/// (items reference it weakly).
final class MenuBridge: NSObject {
    private let perform: (MenuCommand) -> Void
    private var commands: [MenuCommand] = []

    init(perform: @escaping (MenuCommand) -> Void) {
        self.perform = perform
    }

    /// A fresh menu for `spec`.
    func menu(_ spec: MenuSpec) -> NSMenu {
        commands.removeAll()
        let menu = NSMenu()
        fill(menu, spec.items)
        return menu
    }

    /// Replaces `menu`'s items with `spec`'s (status menu refresh).
    func fill(_ menu: NSMenu, with spec: MenuSpec) {
        commands.removeAll()
        menu.removeAllItems()
        fill(menu, spec.items)
    }

    private func fill(_ menu: NSMenu, _ items: [MenuItem]) {
        menu.autoenablesItems = false
        for item in items {
            switch item.content {
            case .separator:
                menu.addItem(.separator())
            case let .command(command):
                let ns = NSMenuItem(title: Self.title(item), action: #selector(choose(_:)), keyEquivalent: "")
                ns.target = self
                ns.tag = commands.count
                ns.isEnabled = item.isEnabled
                ns.state = item.isChecked ? .on : .off
                ns.identifier = NSUserInterfaceItemIdentifier(item.id)
                commands.append(command)
                menu.addItem(ns)
            case let .submenu(children):
                let ns = NSMenuItem(title: Self.title(item), action: nil, keyEquivalent: "")
                ns.isEnabled = item.isEnabled
                ns.identifier = NSUserInterfaceItemIdentifier(item.id)
                let sub = NSMenu(title: item.title)
                fill(sub, children)
                ns.submenu = sub
                menu.addItem(ns)
            }
        }
    }

    // MARK: system (M12)
    /// The item's title in the current language (`L10n.tr`); List Contents' file names stay as they are.
    static func title(_ item: MenuItem) -> String {
        item.id.hasPrefix("list.") && item.id != "list.more" ? item.title : L10n.tr(item.title)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard commands.indices.contains(sender.tag) else { return }
        perform(commands[sender.tag])
    }
}
