import DeskCore
import SpriteKit

/// The drive hub (DESIGN §2.2 E15). Covering the Finder desktop also covers its drive icons, so each mounted volume
/// Finder would show (`DeskState.volumes`, from `VolumeWatcher`) stands plugged into the hub: a USB stick, a disk
/// or a server box (`PropArt.drive`), at most `MenuSpec.hubSlots`; the rest sit behind a "+n" tag beside the hub.
/// Hovering a drive names it; a double-click opens it in Finder; its menu offers Open, Show in Finder and Eject
/// (explicit, through `FileOperator`). The "+n" tag's click or menu lists the others. Tokens dropped on the hub or
/// a drive bonk: copying to drives is Finder's job in v0.1. The room keeps drawing the hub itself.
final class DriveHubElement: DeskElement {
    let id = "hub"
    let root = SKNode()
    unowned let context: SceneContext
    /// The room's placed hub (its sprite and alpha hit tests).
    let placed: () -> PlacedElement?

    /// The volumes on the hub, and the ones behind the "+n" tag.
    private(set) var shown: [VolumeEntry] = []
    private(set) var more: [VolumeEntry] = []
    /// Each shown drive's sprite and canvas rect, in hub order.
    private(set) var drives: [(image: PixelBuffer, rect: ArtRect)] = []
    /// The "+n" tag's canvas rect, while there is one.
    private(set) var moreRect: ArtRect?
    private var nodes: [SKSpriteNode] = []
    private let moreNode = SKSpriteNode()
    private var hub = ArtRect.zero

    init(context: SceneContext, placed: @escaping () -> PlacedElement?) {
        self.context = context
        self.placed = placed
        moreNode.isHidden = true
        root.addChild(moreNode)
    }

    func layout(_ layout: SceneLayout) {
        hub = layout.rect(CoreLayout.driveHub)
        rebuild()
    }

    func apply(_ state: DeskState) {
        let split = MenuSpec.hubSplit(state.volumes)
        guard split.shown != shown || split.more != more else { return }
        shown = split.shown
        more = split.more
        rebuild()
    }

    /// The sprite for a volume: a stick for removable media, a box for a server, a disk otherwise.
    static func driveKind(_ kind: VolumeEntry.Kind) -> PropArt.DriveKind {
        switch kind {
        case .removable: .usb
        case .server: .server
        case .internalDisk, .externalDisk: .disk
        }
    }

    static func kindTitle(_ kind: VolumeEntry.Kind) -> String {
        switch kind {
        case .removable: "Removable drive"
        case .server: "Server"
        case .externalDisk: "External disk"
        case .internalDisk: "Disk"
        }
    }

    /// Lays the drives into the hub's slots (standing in its ports) and the "+n" tag beside it.
    private func rebuild() {
        for n in nodes { n.removeFromParent() }
        nodes = []
        drives = []
        let z = context.placementZ("hub") + 0.5
        for (i, v) in shown.enumerated() {
            let image = PropArt.drive(Self.driveKind(v.kind)).image
            let slot = PropArt.driveSlot(i)
            let rect = ArtRect(hub.x + slot.x, hub.y + slot.y + 1 - image.height, image.width, image.height)
            let node = SKSpriteNode(texture: TextureFactory.texture(image))
            node.zPosition = z
            context.space.place(node, at: rect)
            root.addChild(node)
            nodes.append(node)
            drives.append((image, rect))
        }
        if more.isEmpty {
            moreRect = nil
            moreNode.isHidden = true
        } else {
            let badge = Digits.badge("+\(more.count)", fill: .neutral3, ink: .neutral9, rim: .neutral1)
            let rect = ArtRect(hub.maxX + 1, hub.maxY - badge.height, badge.width, badge.height)
            moreNode.texture = TextureFactory.texture(badge)
            moreNode.zPosition = z
            context.space.place(moreNode, at: rect)
            moreNode.isHidden = false
            moreRect = rect
        }
    }

    // MARK: Hits

    /// The shown drive under `p` (its opaque pixels), if any.
    func drive(at p: ArtPoint) -> Int? {
        drives.indices.last { i in
            let d = drives[i]
            return d.rect.contains(p) && d.image.pixel(p.x - d.rect.x, p.y - d.rect.y).a != 0
        }
    }

    /// The volume a hit names: a shown drive (`hub.drive.<i>`).
    func volume(_ hit: Hit) -> VolumeEntry? {
        guard let part = hit.part, part.hasPrefix("hub.drive."), let i = Int(part.dropFirst(10)), shown.indices.contains(i)
        else { return nil }
        return shown[i]
    }

    func hitTest(_ p: ArtPoint) -> Hit? {
        if let i = drive(at: p) { return Hit(element: id, part: "hub.drive.\(i)", rect: drives[i].rect) }
        if let r = moreRect, r.contains(p) { return Hit(element: id, part: "hub.more", rect: r) }
        return placed()?.hitTest(p).map { Hit(element: id, part: $0.part, rect: $0.rect) }
    }

    /// Anchors that follow the drives (demo scripts): `hub.drive.<i>`, `hub.more`.
    func anchor(_ name: String) -> ArtRect? {
        if name == "hub.more" { return moreRect }
        guard name.hasPrefix("hub.drive."), let i = Int(name.dropFirst(10)), drives.indices.contains(i) else { return nil }
        return drives[i].rect
    }

    func hoverStyle(_ hit: Hit) -> HoverStyle {
        hit.part == nil ? RoomContent.silhouetteRing(placed()) : .standard
    }

    func tooltip(_ hit: Hit) -> TooltipSpec? {
        if let v = volume(hit) {
            var spec = TooltipSpec(title: v.name, detail: Self.kindTitle(v.kind), anchor: hit.rect)
            spec.prefersAbove = true
            return spec
        }
        if hit.part == "hub.more" {
            return TooltipSpec(title: "\(more.count) more drive\(more.count == 1 ? "" : "s")", anchor: hit.rect)
        }
        let n = shown.count + more.count
        return TooltipSpec(title: "Drive Hub", detail: n == 0 ? "No drives" : "\(n) drive\(n == 1 ? "" : "s")",
                           anchor: hit.rect)
    }

    // MARK: Gestures

    func handle(_ gesture: Gesture, _ hit: Hit) -> GestureResponse {
        switch gesture {
        case .press, .cancelPress:
            return .handled
        case let .click(p, _, count):
            if count == 2, let v = volume(hit) {
                context.dispatch(.requestOpenVolume(v.id))
            } else if count == 1, hit.part == "hub.more" {
                context.request(.menu(MenuSpec.drives(more, from: MenuSpec.hubSlots), at: p))
            }
            return .handled
        case .dragBegan, .scroll:
            return .pass
        }
    }

    /// Copying to drives is Finder's job (v0.1): drops on the hub, a drive or the tag bonk.
    func dropVerdict(_ tokens: [TokenKey], at p: ArtPoint) -> DropVerdict? {
        hitTest(p) == nil ? nil : .bonk(.drivesReadOnly)
    }

    func menu(_ hit: Hit) -> MenuSpec? {
        if let v = volume(hit) { return MenuSpec.drive(v) }
        if hit.part == "hub.more" { return MenuSpec.drives(more, from: MenuSpec.hubSlots) }
        let all = shown + more
        return all.isEmpty ? nil : MenuSpec.drives(all)
    }

    func accessibilityItems() -> [AXItem] {
        var items = shown.enumerated().map { i, v in
            AXItem(id: "drive.\(v.id)", label: "Drive \(v.name)", role: .button, frame: drives[i].rect)
        }
        if let r = moreRect {
            items.append(AXItem(id: "drive.more", label: "\(more.count) more drives", role: .button, frame: r))
        }
        return items
    }
}
