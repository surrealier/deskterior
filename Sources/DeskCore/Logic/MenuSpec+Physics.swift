/// Context menus of the pen cup and the wastebasket (DESIGN §2.2 E7, E8).
extension MenuSpec {
    /// Right-click on the pen cup: Tip Over while it stands, Stand Up while it lies.
    public static func penCup(_ s: DeskState) -> MenuSpec {
        let upright = s.penCup.state == PenCupMachine.uprightName
        return MenuSpec([
            MenuItem("tipOver", "Tip Over", .tipOver(.penCup), enabled: upright),
            MenuItem("standUp", "Stand Up", .standUp(.penCup), enabled: !upright),
        ])
    }

    /// Right-click on the wastebasket: Tip Over / Stand Up, and Empty Wastebasket… (which waits for M11's
    /// `FileOperator`; the basket never empties itself).
    public static func wastebasket(_ s: DeskState) -> MenuSpec {
        let upright = s.wastebasket.state == WastebasketMachine.uprightName
        let binned = s.tokens.count(in: .wastebasket)
        return MenuSpec([
            MenuItem("tipOver", "Tip Over", .tipOver(.wastebasket), enabled: upright),
            MenuItem("standUp", "Stand Up", .standUp(.wastebasket), enabled: !upright),
            .separator,
            MenuItem("emptyWastebasket", binned > 0 ? "Empty Wastebasket… (\(binned))" : "Empty Wastebasket…",
                     .emptyWastebasket, enabled: binned > 0 && !pending.contains("emptyWastebasket")),
        ])
    }
}
