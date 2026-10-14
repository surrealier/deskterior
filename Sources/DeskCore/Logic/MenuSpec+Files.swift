/// Drive hub menus (DESIGN §2.2 E15, §4.9). No key equivalents; Eject is explicit and runs through `FileOperator`.
extension MenuSpec {
    /// Drives the hub shows; the rest sit behind its "+n" tag.
    public static let hubSlots = 4

    /// Right-click on a drive: Open, Show in Finder, Eject (off for a volume that cannot be ejected). `prefix` keeps
    /// ids unique when the items sit in a submenu (`drive.2.eject`).
    public static func drive(_ v: VolumeEntry, prefix: String = "drive") -> MenuSpec {
        MenuSpec([
            MenuItem("\(prefix).open", "Open", .openVolume(v.id)),
            MenuItem("\(prefix).reveal", "Show in Finder", .revealVolume(v.id)),
            .separator,
            MenuItem("\(prefix).eject", "Eject “\(v.name)”", .ejectVolume(v.id), enabled: v.isEjectable),
        ])
    }

    /// One submenu per volume (`drive.<i>.open`…, `i` counting from the first listed): the "+n" tag's menu, and the
    /// hub's own menu with every drive.
    public static func drives(_ volumes: [VolumeEntry], from first: Int = 0) -> MenuSpec {
        MenuSpec(volumes.enumerated().map { i, v in
            MenuItem("drive.\(first + i)", v.name, submenu: drive(v, prefix: "drive.\(first + i)").items)
        })
    }

    /// The hub's drives (the first `hubSlots` volumes) and the ones behind its "+n" tag.
    public static func hubSplit(_ volumes: [VolumeEntry]) -> (shown: [VolumeEntry], more: [VolumeEntry]) {
        (Array(volumes.prefix(hubSlots)), Array(volumes.dropFirst(hubSlots)))
    }
}
