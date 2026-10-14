import DeskCore
import SpriteKit

/// The desk plane in the room (M7): the `PhysicsHub` and its elements join the hit-test order in the slots of the
/// objects they draw — the pen cup and the loose piles in the pen cup's (piles draw in front of the desk-front
/// props they stand before), the wastebasket and floor tokens in the basket's, the knock in the apron's — and the
/// room's static cup and basket sprites give way to them.
extension RoomContent {
    /// Builds the hub and installs its elements (called once from `init`).
    func installPhysics() {
        let hub = PhysicsHub(context: context)
        context.physics = hub
        hub.eventTime = { [unowned self] in router.now }
        hub.knockables = { [unowned self] in extras.compactMap { $0 as? any Knockable } }
        hub.apron.wobbleNodes = { [unowned self] prop in wobbleNodes(prop) }
        hub.hidePlacements = { [unowned self] in hidePhysicsPlacements() }
        hub.chairLeft = { [unowned self] in Float(state.chairX) }
        install([hub.cup, hub.piles], inSlotOf: "pencup")
        install([hub.basket, hub.floor], inSlotOf: "wastebasket")
        install([hub.apron], inSlotOf: "desk")
        hidePhysicsPlacements()
    }

    /// The room draws the cup and the basket through these elements now.
    func hidePhysicsPlacements() {
        for e in elements where e.id == "pencup" || e.id == "wastebasket" { e.root.isHidden = true }
    }

    /// Every node that shakes when `prop` wobbles: its room sprites and the elements in its slot.
    func wobbleNodes(_ prop: DeskKnock.Wobbler) -> [SKNode] {
        let slot: String
        switch prop {
        case .monitor: slot = "monitor"
        case .phone: slot = "phone"
        case .lamp: slot = "lamp"
        case .plant: slot = "plant"
        case .keyboard: slot = "keyboard"
        case .penCup: return []
        }
        var nodes: [SKNode] = elements.filter { $0.id == slot }.map(\.root)
        // Elements drawing over the prop (the monitor's screen and controls, a phone element).
        nodes += extras.filter { $0.id == slot || $0.id.hasPrefix(slot + ".") || (slot == "monitor" && $0 === screen) }
            .map(\.root)
        return nodes
    }

    /// After SpriteKit's physics step (`DeskScene.didSimulatePhysics`).
    func didSimulatePhysics() {
        hidePhysicsPlacements()
        context.physics?.didSimulate()
    }

    /// Model animations the desk plane plays: tip over / stand up, bonks on the cup and the basket where they stand.
    func playPhysics(_ id: AnimationID, _ target: AnimTarget) -> Bool {
        guard let hub = context.physics else { return false }
        switch (id, target) {
        case (.tipOver, .container(.penCup)): hub.cup.tipOut()
        case (.standUp, .container(.penCup)): hub.cup.standUp()
        case (.tipOver, .container(.wastebasket)): hub.basket.tipOut()
        case (.standUp, .container(.wastebasket)): hub.basket.standUp()
        case (.bonk, .container(.penCup)):
            let r = hub.cup.bounds
            context.fx.pop(.bonk, at: ArtPoint(r.midX, r.minY))
            context.shake(frames: 2)
            hub.cup.bonked()
        case (.bonk, .container(.wastebasket)):
            let r = hub.basket.mouthRect
            context.fx.pop(.bonk, at: ArtPoint(r.midX, r.minY))
            context.shake(frames: 2)
            hub.basket.bonked()
        case let (.poof, .location(.floor(x))):
            context.fx.puff(at: layout.point(ArtPoint(x, CoreLayout.floorY)))
        default:
            return false
        }
        return true
    }

    /// A real icon arrived: a pile or floor token holding it redraws.
    func physicsIconChanged(_ key: TokenKey) {
        guard let hub = context.physics, let loc = context.state?.tokens.location(of: key) else { return }
        switch loc {
        case .desk: hub.piles.iconChanged()
        case .floor: hub.floor.iconChanged()
        default: break
        }
    }
}

// MARK: - Scene access (demos, tests)

extension DeskScene {
    /// The canvas rect of a token's icon off the screen: in a pile, on the floor (nil elsewhere).
    public func deskTokenRect(_ key: TokenKey) -> ArtRect? {
        guard let hub = room?.context.physics else { return nil }
        return hub.piles.iconRect(of: key) ?? hub.floor.iconRect(of: key)
    }

    /// Where the desk-plane objects are now (canvas px): `pencup`, `pencup.mouth`, `pencup.body`, `wastebasket`,
    /// `wastebasket.mouth`, `wastebasket.body`; nil for other names.
    public func physicsAnchor(_ name: String) -> ArtRect? {
        guard let hub = room?.context.physics else { return nil }
        let cup = hub.cup.bounds, basket = hub.basket.bounds
        switch name {
        case "pencup": return cup
        case "pencup.mouth": return ArtRect(cup.x, cup.y, cup.w, 5)
        case "pencup.body": return ArtRect(cup.x, cup.maxY - 12, cup.w, 10)
        case "wastebasket": return basket
        case "wastebasket.mouth": return hub.basket.mouthRect
        case "wastebasket.body": return ArtRect(basket.x + 4, basket.maxY - 20, basket.w - 8, 12)
        default: return nil
        }
    }

    /// Demo expectations about the desk plane (`docs/DEMOS.md`): `penCup` / `wastebasket` (the model's state),
    /// `penCup.pose` / `wastebasket.pose` (the scene's), `swishes`, `piles` (piles holding tokens), `floor` and
    /// `pens` / `balls` (token counts), `flying` (tokens in the air), `knocks` (desk knocks so far). Nil for other keys.
    public func physicsExpectation(_ key: String) -> String? {
        guard let hub = room?.context.physics, let s = deskState else { return nil }
        switch key {
        case "penCup": return s.penCup.state
        case "penCup.pose": return "\(hub.cup.machine.phase)"
        case "wastebasket": return s.wastebasket.state
        case "wastebasket.pose": return "\(hub.basket.machine.phase)"
        case "swishes": return String(s.wastebasket.swishes)
        case "piles": return String(s.tokens.piles.count)
        case "floor": return String(s.tokens.keys { if case .floor = $0 { true } else { false } }.count)
        case "pens": return String(s.tokens.count(in: .penCup))
        case "balls": return String(s.tokens.count(in: .wastebasket))
        case "flying": return String(hub.tosses.flyingKeys.count)
        case "knocks": return String(hub.knocks)
        default: return nil
        }
    }

    /// Desk-plane positions of every pile (for determinism checks).
    public var pilePositions: [PileID: SIMD2<Float>] {
        room?.context.physics?.bodies.positions ?? [:]
    }

    /// Desk-plane physics, right after SpriteKit stepped the world (DESIGN §4.6 step 5).
    func physicsDidSimulate() {
        room?.didSimulatePhysics()
    }
}
