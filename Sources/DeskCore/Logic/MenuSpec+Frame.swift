/// The picture frame's menu (Erratum 33). Titles carry no user text (never a file name). Put Away Wall Shelf follows:
/// the room appends it for the `frame` element (`StowCatalog.stowID(forElement:)`), as for the plant.
extension MenuSpec {
    /// Right-click on the picture frame: Choose Photo…, and Remove Photo while one is hung.
    public static func frame(_ s: DeskState) -> MenuSpec {
        var items = [MenuItem("choosePhoto", "Choose Photo…", .choosePhoto)]
        if s.framePhoto != nil { items.append(MenuItem("removePhoto", "Remove Photo", .removePhoto)) }
        return MenuSpec(items)
    }
}
