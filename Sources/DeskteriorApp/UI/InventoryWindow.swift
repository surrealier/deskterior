import AppKit
import DeskCore
import DeskPixels
import DeskScene
import Observation
import SwiftUI

/// Find Item… / Inventory (DESIGN §2.2 E16): every token wherever it lives — any monitor page, any drawer, the
/// phone, the cup, the basket, under the mat — with its kind icon, name, location label, kind and date added,
/// searchable (NFC, case- and diacritic-insensitive) and sortable by any column. Open (⌘O), Quick Look (⌘Y), Show
/// in Finder (⌘R), Take Out, **Show on Desk** (Return: powers on, switches the page, opens the drawer… then
/// selects and pulses the token; the window steps off the monitor so the pulse shows) and Take Everything Out.
/// Esc or ⌘W closes it; ⌘F brings it back with the search selected. It is also the accessible path to
/// everything: a plain, keyboard-driven table.
final class InventoryWindowController: NSObject, NSWindowDelegate {
    private let model: InventoryModel
    private var window: NSWindow?
    private var observer: Int?
    private unowned let store: Store
    /// The monitor's glass in screen coordinates, for Show on Desk.
    var monitorFrame: (() -> NSRect?)?
    // MARK: mat
    /// The piles the desk mat covers now ("Under mat").
    var coveredPiles: () -> Set<PileID> {
        get { model.coveredPiles }
        set { model.coveredPiles = newValue }
    }

    init(store: Store, perform: @escaping (MenuCommand) -> Void) {
        self.store = store
        model = InventoryModel(state: store.state, perform: perform)
        super.init()
        model.onShowOnDesk = { [weak self] in self?.stepOffMonitor() }
        model.onClose = { [weak self] in self?.window?.performClose(nil) }
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
        model.focusSearch += 1
    }

    func windowWillClose(_ notification: Notification) {
        if let observer { store.removeObserver(observer) }
        observer = nil
    }

    /// Moves the window beside the monitor (or out of the way) so Show on Desk's pulse is not hidden under it.
    private func stepOffMonitor() {
        guard let window, let monitor = monitorFrame?(), window.frame.intersects(monitor),
              let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame, size = window.frame.size, gap: CGFloat = 16
        let candidates = [
            NSPoint(x: monitor.maxX + gap, y: window.frame.minY),
            NSPoint(x: monitor.minX - gap - size.width, y: window.frame.minY),
            NSPoint(x: window.frame.minX, y: monitor.minY - gap - size.height),
            NSPoint(x: window.frame.minX, y: monitor.maxY + gap),
        ]
        for origin in candidates {
            var frame = NSRect(origin: origin, size: size)
            frame.origin.x = min(max(frame.minX, area.minX), area.maxX - size.width)
            frame.origin.y = min(max(frame.minY, area.minY), area.maxY - size.height)
            if area.contains(frame), !frame.intersects(monitor) {
                window.setFrame(frame, display: true, animate: true)
                return
            }
        }
        // No room beside it: get out of the way (⌘F brings the window back).
        window.orderOut(nil)
    }
}

/// The Inventory's data: the model state, the search text, the sort and the selected rows.
@Observable
final class InventoryModel {
    var state: DeskState
    var search = ""
    var selection = Set<TokenKey>()
    var sortOrder = [KeyPathComparator(\InventoryItem.name, comparator: .localizedStandard)]
    /// Bumped to put the cursor in the search field.
    var focusSearch = 0
    let perform: (MenuCommand) -> Void
    var onShowOnDesk: (() -> Void)?
    var onClose: (() -> Void)?
    // MARK: mat
    @ObservationIgnored var coveredPiles: () -> Set<PileID> = { [] }

    init(state: DeskState, perform: @escaping (MenuCommand) -> Void) {
        self.state = state
        self.perform = perform
    }

    var items: [InventoryItem] {
        InventoryQuery.items(state, search: search, coverage: .init(coveredPiles: coveredPiles())).sorted(using: sortOrder)  // MARK: mat
    }

    var selectedKeys: [TokenKey] { items.map(\.key).filter(selection.contains) }

    /// The single selected token, for Show on Desk.
    var single: TokenKey? { selectedKeys.count == 1 ? selectedKeys[0] : nil }

    /// Selected tokens that are not on the monitor (what Take Out would bring out).
    var takeOutKeys: [TokenKey] { selectedKeys.filter { state.tokens.location(of: $0)?.isScreen == false } }

    func run(_ command: MenuCommand) { perform(command) }

    func showOnDesk(_ key: TokenKey) {
        perform(.showOnDesk(key))
        onShowOnDesk?()
    }

    func takeOut() {
        let keys = takeOutKeys
        guard !keys.isEmpty else { return }
        perform(.moveTo(keys, ScreenGrid.standard.firstFree(state.tokens.occupiedCells).location))
    }

    /// "PDF document", "Folder"… as the desk's tooltips say it.
    func kindName(_ item: InventoryItem) -> String {
        TokenArt.kindName(item.kind, package: state.tokens.meta(of: item.key)?.isPackage ?? false)
    }
}

extension InventoryItem {
    /// Sort keys for the Kind and Date Added columns.
    var kindSortKey: String { kind.rawValue }
    var addedSortKey: Date { added ?? .distantPast }
}

struct InventoryView: View {
    @Bindable var model: InventoryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search all items", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                Text("\(model.items.count) of \(model.state.tokens.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(10)
            Table(model.items, selection: $model.selection, sortOrder: $model.sortOrder) {
                TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                    HStack(spacing: 6) {
                        Image(nsImage: KindIconImages.image(item.kind))
                            .interpolation(.none)
                            .frame(width: 16, height: 16)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Location", value: \.label) { item in
                    Text(item.label).foregroundStyle(item.isHidden ? .secondary : .primary)
                }
                .width(min: 120, ideal: 160)
                TableColumn("Kind", value: \.kindSortKey) { item in Text(model.kindName(item)) }
                    .width(min: 60, ideal: 100)
                TableColumn("Date Added", value: \.addedSortKey) { item in
                    Text(item.added.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                }
                .width(min: 80, ideal: 110)
            }
            .contextMenu(forSelectionType: TokenKey.self) { keys in
                Button("Open") { model.run(.open(Array(keys))) }
                Button("Quick Look") { model.run(.quickLook(Array(keys))) }
                Button("Show in Finder") { model.run(.reveal(Array(keys))) }
                if keys.count == 1, let key = keys.first {
                    Button("Show on Desk") { model.showOnDesk(key) }
                }
            } primaryAction: { keys in
                if keys.count == 1, let key = keys.first { model.showOnDesk(key) }
            }
            Divider()
            HStack {
                Button("Open") { model.run(.open(model.selectedKeys)) }
                    .keyboardShortcut("o")
                    .disabled(model.selectedKeys.isEmpty)
                Button("Quick Look") { model.run(.quickLook(model.selectedKeys)) }
                    .keyboardShortcut("y")
                    .disabled(model.selectedKeys.isEmpty)
                Button("Show in Finder") { model.run(.reveal(model.selectedKeys)) }
                    .keyboardShortcut("r")
                    .disabled(model.selectedKeys.isEmpty)
                Button("Take Out") { model.takeOut() }
                    .disabled(model.takeOutKeys.isEmpty)
                Spacer()
                Button("Take Everything Out") { model.run(.takeEverythingOut) }
                Button("Show on Desk") { if let key = model.single { model.showOnDesk(key) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.single == nil)
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 280)
        .onExitCommand { model.onClose?() }
        .onChange(of: model.focusSearch, initial: true) {
            // Refocusing selects the search text, ready to type over.
            searchFocused = false
            DispatchQueue.main.async { searchFocused = true }
        }
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
