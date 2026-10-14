import Foundation

/// One row of the Find Item… / Inventory window (DESIGN §2.2 E16).
public struct InventoryItem: Sendable, Equatable, Identifiable {
    public var key: TokenKey
    public var name: String
    public var kind: FileKind
    public var added: Date?
    public var location: Location
    /// "Monitor · HDMI 2", "Cabinet ▸ middle", "Under mat", "Wastebasket"…
    public var label: String
    public var isHidden: Bool

    public var id: TokenKey { key }
}

/// A flat, searchable listing of every token with a location label.
public enum InventoryQuery {
    /// Items whose NFC name contains `search` (case-, width- and diacritic-insensitive; empty matches all),
    /// sorted by name.
    public static func items(
        _ state: DeskState, search: String = "", coverage: Visibility.Coverage = .none
    ) -> [InventoryItem] {
        let needle = TextLayout.nfc(search.trimmingCharacters(in: .whitespaces))
        let keys = Placement.byName(state.tokens.sortedKeys, in: state.tokens)
        return keys.compactMap { key in
            let record = state.tokens[key]!
            let meta = record.meta
            if !needle.isEmpty,
               meta.displayName.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == nil
            {
                return nil
            }
            let covered = record.location.pile.map { coverage.coveredPiles.contains($0) } ?? false
            return InventoryItem(
                key: key, name: meta.displayName, kind: meta.kind, added: meta.added, location: record.location,
                label: label(for: record.location, covered: covered),
                isHidden: Visibility.of(record.location, state, coverage).isHidden
            )
        }
    }

    /// The human label of a location (English; the Find Item window shows it through `L10n.tr`).
    public static func label(for location: Location, covered: Bool = false) -> String {
        switch location {
        case let .screen(page, _, _): "Monitor · HDMI \(page + 1)"
        case let .container(id, _): label(for: id)
        case .desk: covered ? "Under mat" : "Desk"
        case .floor: "Floor"
        case .carried: "In hand"
        }
    }

    public static func label(for id: ContainerID) -> String {
        switch id {
        case .riserLeft: "Riser ▸ left drawer"
        case .riserRight: "Riser ▸ right drawer"
        case .riserCubby: "Riser ▸ cubby"
        case .cabinetTop: "Cabinet ▸ top"
        case .cabinetMiddle: "Cabinet ▸ middle"
        case .cabinetFile: "Cabinet ▸ file"
        case .penCup: "Pen cup"
        case .phone: "Phone"
        case .wastebasket: "Wastebasket"
        }
    }
}
