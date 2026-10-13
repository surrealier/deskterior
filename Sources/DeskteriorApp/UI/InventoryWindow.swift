import AppKit
import DeskCore
import DeskPixels
import Observation
import SwiftUI

/// Find Item… / Inventory (DESIGN §2.2 E16): every token wherever it lives — any monitor page, any drawer, the
/// phone, the cup, the basket, under the mat — with its kind icon, name, location label, kind and date added,
/// searchable (NFC, case- and diacritic-insensitive). Open, Quick Look, Show in Finder, Take Out, **Show on
/// Desk** (powers on, switches the page, opens the drawer… then pulses the token) and Take Everything Out. It is
/// also the accessible path to everything: a plain, keyboard-driven table.
final class InventoryWindowController: NSObject, NSWindowDelegate {
    private let model: InventoryModel
    private var window: NSWindow?
    private var observer: Int?
    private unowned let store: Store

    init(store: Store, perform: @escaping (MenuCommand) -> Void) {
        self.store = store
        model = InventoryModel(state: store.state, perform: perform)
        super.init()
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
            )
            w.title = "Find Item"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 520, height: 280)
            w.contentViewController = NSHostingController(rootView: InventoryView(model: model))
            w.center()
            w.delegate = self
            window = w
        }
        if observer == nil {
            observer = store.observe { [weak self] new, _ in self?.model.state = new }
        }
        model.state = store.state
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let observer { store.removeObserver(observer) }
        observer = nil
    }
}

/// The Inventory's data: the model state, the search text and the selected rows.
@Observable
final class InventoryModel {
    var state: DeskState
    var search = ""
    var selection = Set<TokenKey>()
    let perform: (MenuCommand) -> Void

    init(state: DeskState, perform: @escaping (MenuCommand) -> Void) {
        self.state = state
        self.perform = perform
    }

    var items: [InventoryItem] { InventoryQuery.items(state, search: search) }

    var selectedKeys: [TokenKey] { items.map(\.key).filter(selection.contains) }

    /// The single selected token, for Show on Desk.
    var single: TokenKey? { selectedKeys.count == 1 ? selectedKeys[0] : nil }

    func run(_ command: MenuCommand) { perform(command) }

    func takeOut() {
        let keys = selectedKeys.filter { state.tokens.location(of: $0)?.isScreen == false }
        guard !keys.isEmpty else { return }
        perform(.moveTo(keys, ScreenGrid.standard.firstFree(state.tokens.occupiedCells).location))
    }
}

struct InventoryView: View {
    @Bindable var model: InventoryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search all items", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                Text("\(model.items.count) of \(model.state.tokens.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(10)
            Table(model.items, selection: $model.selection) {
                TableColumn("Name") { item in
                    HStack(spacing: 6) {
                        Image(nsImage: KindIconImages.image(item.kind))
                            .interpolation(.none)
                            .frame(width: 16, height: 16)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Location") { item in
                    Text(item.label).foregroundStyle(item.isHidden ? .secondary : .primary)
                }
                .width(min: 120, ideal: 160)
                TableColumn("Kind") { item in Text(item.kind.rawValue.capitalized) }
                    .width(min: 60, ideal: 80)
                TableColumn("Date Added") { item in
                    Text(item.added.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                }
                .width(min: 80, ideal: 110)
            }
            .contextMenu(forSelectionType: TokenKey.self) { keys in
                Button("Open") { model.run(.open(Array(keys))) }
                Button("Quick Look") { model.run(.quickLook(Array(keys))) }
                Button("Show in Finder") { model.run(.reveal(Array(keys))) }
                if keys.count == 1, let key = keys.first {
                    Button("Show on Desk") { model.run(.showOnDesk(key)) }
                }
            } primaryAction: { keys in
                if keys.count == 1, let key = keys.first { model.run(.showOnDesk(key)) }
            }
            Divider()
            HStack {
                Button("Open") { model.run(.open(model.selectedKeys)) }
                    .disabled(model.selectedKeys.isEmpty)
                Button("Quick Look") { model.run(.quickLook(model.selectedKeys)) }
                    .disabled(model.selectedKeys.isEmpty)
                Button("Show in Finder") { model.run(.reveal(model.selectedKeys)) }
                    .disabled(model.selectedKeys.isEmpty)
                Button("Take Out") { model.takeOut() }
                    .disabled(model.selectedKeys.isEmpty)
                Spacer()
                Button("Take Everything Out") { model.run(.takeEverythingOut) }
                Button("Show on Desk") { if let key = model.single { model.run(.showOnDesk(key)) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.single == nil)
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 280)
    }
}

/// The hand-drawn kind icons as crisp 16-pt images (1× and 2× nearest-neighbour).
enum KindIconImages {
    private static var cache: [FileKind: NSImage] = [:]

    static func image(_ kind: FileKind) -> NSImage {
        if let hit = cache[kind] { return hit }
        let image = NSImage(size: NSSize(width: 16, height: 16))
        let base = KindIcons.icon(IconKind(rawValue: kind.rawValue) ?? .unknown, size: 16).image
        for factor in [1, 2] {
            guard let cg = base.scaledNearest(factor).makeCGImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: 16, height: 16)
            image.addRepresentation(rep)
        }
        cache[kind] = image
        return image
    }
}
