import DeskCore

/// The M6 hiding places in the room (DESIGN §2.2 E3–E6, §4.4): the riser, the cabinet, the chair and the phone
/// stand take their placed objects' hit-test slots (`install(_:inSlotOf:)`) and draw in place of the room's
/// sprites once a model arrives. Also the entry points other tracks call: the desk knock (M7), slam
/// notifications, and the model's container animations (a handle wiggle, Show on Desk's pulse).
extension RoomContent {
    /// Builds and installs the container elements (called once from `init`).
    func installContainers() {
        let riser = RiserElement(context: context)
        let cabinet = CabinetElement(context: context)
        let chair = ChairElement(context: context)
        let phone = PhoneStandElement(context: context)
        cabinet.chair = chair
        chair.cabinet = cabinet
        let slots: [(ContainerElement, String)] = [
            (riser, "riser"), (cabinet, "cabinet"), (chair, "chair"), (phone, "phone"),
        ]
        for (element, slot) in slots {
            element.placed = { [unowned self] in elements.first { $0.id == slot } }
            element.activeCarry = { [unowned self] in router.drag as? CarrySession }
            element.refreshHover = { [unowned self] in _ = router.refreshHover() }
        }
        install([riser], inSlotOf: "riser")
        install([cabinet], inSlotOf: "cabinet")
        install([chair], inSlotOf: "chair")
        install([phone], inSlotOf: "phone")
    }

    var riserElement: RiserElement? { extras.lazy.compactMap { $0 as? RiserElement }.first }
    var cabinetElement: CabinetElement? { extras.lazy.compactMap { $0 as? CabinetElement }.first }
    var chairElement: ChairElement? { extras.lazy.compactMap { $0 as? ChairElement }.first }
    var phoneElement: PhoneStandElement? { extras.lazy.compactMap { $0 as? PhoneStandElement }.first }

    /// Every drawer's live sim (for `DeskKnock.plan(for:drawers:…)`).
    var drawerSims: [ContainerID: DrawerSim] {
        let units = (riserElement?.units ?? []) + (cabinetElement?.units ?? [])
        return Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0.sim) })
    }

    /// The desk knock's effect on the containers (M7 calls this with a `DeskKnock.Plan`): ajar drawers within
    /// reach snap shut, drawer contents hop, the phone wobbles. Membership never changes.
    func knockContainers(_ plan: DeskKnock.Plan) {
        riserElement?.knock(plan)
        cabinetElement?.knock(plan)
        if let hop = plan.wobbles[.phone] { phoneElement?.knock(hop) }
    }

    /// Calls `handler` when a drawer slams shut (container, speed px/s): the trigger for a desk knock (M7).
    func onDrawerSlam(_ handler: ((ContainerID, Float) -> Void)?) {
        riserElement?.onSlam = handler
        cabinetElement?.onSlam = handler
    }

    /// A model animation aimed at a container (`Effect.play`): the handle wiggles when a member's file went away.
    func playContainer(_ id: AnimationID, _ target: AnimTarget) {
        guard id == .handleWiggle, case let .container(c) = target else { return }
        (riserElement?.unit(c) ?? cabinetElement?.unit(c))?.wiggle()
    }

    /// Show on Desk's pulse for a token in a container: it is selected once on show and blinks.
    func pulseContainers(_ key: TokenKey) {
        guard let s = context.state, case let .container(id, _)? = s.tokens.location(of: key) else { return }
        let element: ContainerElement? = switch id {
        case .riserLeft, .riserRight, .riserCubby: riserElement
        case .cabinetTop, .cabinetMiddle, .cabinetFile: cabinetElement
        case .phone: phoneElement
        default: nil
        }
        element?.playPulse(key)
    }

    /// The live rect of an anchor that moves with a container (a drawer's pull and front), else nil.
    func liveContainerAnchor(_ name: String) -> ArtRect? {
        riserElement?.liveAnchor(name) ?? cabinetElement?.liveAnchor(name)
    }

    /// Where `key` shows as a mini in an open container (canvas px), if it does.
    func containerMiniRect(of key: TokenKey) -> ArtRect? {
        riserElement?.miniRect(of: key) ?? cabinetElement?.miniRect(of: key) ?? phoneElement?.miniRect(of: key)
    }
}
