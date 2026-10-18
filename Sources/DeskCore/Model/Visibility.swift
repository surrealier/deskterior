/// How a token at some location shows up and whether it can be hit (DESIGN §2.1 visibility matrix).
public struct Visibility: Sendable, Equatable, CustomStringConvertible {
    public enum Appearance: String, Sendable {
        /// The 16×16 icon (screen, uncovered pile, floor, carry).
        case icon
        /// A 12×12 mini (open drawer) or 5×5 app mini (face-up phone).
        case mini
        /// A dim shape without a name (cubby, lamp-only darkness).
        case silhouette
        /// Paper pixels poking out of an ajar drawer.
        case paperEdges
        /// A pen cap coloured by kind.
        case penCap
        /// A crumpled ball in the wastebasket.
        case ball
        /// Only the mat bump shows.
        case bump
        case notShown
    }

    public var appearance: Appearance
    public var hitTestable: Bool

    public init(_ appearance: Appearance, hitTestable: Bool) {
        self.appearance = appearance
        self.hitTestable = hitTestable
    }

    /// The file's identity is not visible to an onlooker (anything but an icon or mini).
    public var isHidden: Bool { appearance != .icon && appearance != .mini }

    public var description: String { "\(appearance.rawValue)\(hitTestable ? "" : " (no hit)")" }

    /// Per-token facts that come from the scene rather than the model.
    public struct Coverage: Sendable, Equatable {
        /// Piles the mat currently covers (DESIGN §2.2 E9 Coverage).
        public var coveredPiles: Set<PileID>
        /// The token sits in lamp-only darkness (light level < 3).
        public var dark: Bool

        public init(coveredPiles: Set<PileID> = [], dark: Bool = false) {
            self.coveredPiles = coveredPiles
            self.dark = dark
        }

        public static let none = Coverage()
    }

    /// A drawer counts as open (minis, hit-testable) from this opening.
    public static let drawerOpen: Float = 8
    /// Below this opening a drawer is closed; between this and `drawerOpen` it peeks (paper edges).
    public static let drawerPeek: Float = 0.5

    /// The matrix itself.
    public static func of(_ location: Location, _ state: DeskState, _ coverage: Coverage = .none) -> Visibility {
        let base: Visibility
        switch location {
        case let .screen(page, _, _):
            let shown = state.monitor.power == .on && !state.monitor.av && state.monitor.page == page
            base = shown ? Visibility(.icon, hitTestable: true) : Visibility(.notShown, hitTestable: false)
        case let .container(id, order):
            base = container(id, order: order, state)
        case let .desk(pile, _):
            base = coverage.coveredPiles.contains(pile)
                ? Visibility(.bump, hitTestable: false) : Visibility(.icon, hitTestable: true)
        case .floor:
            base = Visibility(.icon, hitTestable: true)
        case .carried:
            base = Visibility(.icon, hitTestable: false)
        }
        // Lamp-only darkness turns anything recognizable into a silhouette, and nothing in the dark takes clicks.
        guard coverage.dark else { return base }
        if !base.isHidden || base.appearance == .silhouette { return Visibility(.silhouette, hitTestable: false) }
        return Visibility(base.appearance, hitTestable: false)
    }

    private static func container(_ id: ContainerID, order: Int, _ state: DeskState) -> Visibility {
        switch id {
        case .riserLeft, .riserRight, .cabinetTop, .cabinetMiddle, .cabinetFile:
            let p = state.drawerOpening(id)
            if p >= drawerOpen { return Visibility(.mini, hitTestable: true) }
            if p >= drawerPeek { return Visibility(.paperEdges, hitTestable: false) }
            return Visibility(.notShown, hitTestable: false)
        case .riserCubby:
            return Visibility(.silhouette, hitTestable: true)
        case .phone:
            return state.phone.faceDown ? Visibility(.notShown, hitTestable: false) : Visibility(.mini, hitTestable: true)
        case .penCup:
            // Only the last pen can be pulled out.
            return Visibility(.penCap, hitTestable: order == state.tokens.count(in: .penCup) - 1)
        case .wastebasket:
            // Digging takes the top ball.
            return Visibility(.ball, hitTestable: order == state.tokens.count(in: .wastebasket) - 1)
        case .memoClips:
            // Cards clipped up in sight, each with its mini (Erratum 31).
            return Visibility(.mini, hitTestable: true)
        }
    }
}
