import Foundation

/// Inputs the reducer may read besides the state and the action. The reducer never reads the clock itself.
public struct ReduceEnv: Sendable {
    public var now: Date
    public var seed: UInt64
    public var grid: ScreenGrid

    public init(now: Date, seed: UInt64 = 0, grid: ScreenGrid = .standard) {
        self.now = now
        self.seed = seed
        self.grid = grid
    }
}

/// `reduce(&state, action, env) -> [Effect]`: the one place the model changes. Pure: no I/O, no clock, no
/// randomness except `env.seed`. Only request actions emit effects that touch files. Keys in actions follow
/// recent re-keys (a gesture that began before a safe-save), and non-finite numbers from the scene are refused
/// so the layout always stays encodable.
public func reduce(_ s: inout DeskState, _ a: DeskAction, _ env: ReduceEnv) -> [Effect] {
    Reducer.reduce(&s, a, env)
}

public enum Reducer {
    public static func reduce(_ s: inout DeskState, _ a: DeskAction, _ env: ReduceEnv) -> [Effect] {
        switch a {
        case let .snapshot(snapshot, now):
            return applySnapshot(&s, snapshot, now: now, grid: env.grid)

        case let .volumes(list):
            guard list != s.volumes else { return [] }
            s.volumes = list
            return [.wakeLoop]

        case .accessDenied:
            s.access = .denied
            return [.toast(.accessDenied), .wakeLoop]

        case .accessGranted:
            s.access = .connecting
            return [.wakeLoop]

        case .finderHidesItems:
            guard s.access == .notConnected else { return [] }
            s.access = .finderHidden
            return [.wakeLoop]

        case let .move(keys, to):
            return move(&s, keys.map(s.currentKey), to: to, grid: env.grid)

        case let .settle(report):
            // Landings squash and puff in the scene, which flew them there.
            var changed = false
            for m in report.moves {
                let key = s.currentKey(for: m.key)
                guard s.tokens.contains(key) else { continue }
                // M7: the scene chose the floor spot (stacks share one); it is not spread again.
                if case let .floor(x) = m.to {
                    changed = !dropOnFloor(&s, [key], x: x, grid: env.grid).isEmpty || changed
                    continue
                }
                changed = !move(&s, [key], to: m.to, grid: env.grid).isEmpty || changed
            }
            changed = setPiles(&s, report.piles) || changed
            return changed ? [.persist, .wakeLoop] : []

        case let .power(on):
            let target: PowerState = on ? .on : .off
            guard s.monitor.power != target else { return [] }
            s.monitor.power = target
            if on { s.monitor.pendingNew = 0 }
            return [.play(on ? .crtOn : .crtOff, .monitor), .persist, .wakeLoop]

        case let .setPage(page):
            let p = min(max(page, 0), s.pageCount(grid: env.grid) - 1)
            guard p != s.monitor.page || s.monitor.av else { return [] }
            s.monitor.page = p
            s.monitor.av = false
            return [.play(.staticNoise, .monitor), .play(.osd, .monitor), .persist, .wakeLoop]

        case .cycleInput:
            if s.monitor.av {
                s.monitor.av = false
                s.monitor.page = 0
            } else if s.monitor.page + 1 < s.pageCount(grid: env.grid) {
                s.monitor.page += 1
            } else {
                s.monitor.av = true
            }
            return [.play(.staticNoise, .monitor), .play(.osd, .monitor), .persist, .wakeLoop]

        case .selectAV:
            guard !s.monitor.av else { return [] }
            s.monitor.av = true
            return [.play(.staticNoise, .monitor), .play(.osd, .monitor), .persist, .wakeLoop]

        case let .cleanUp(order):
            let onScreen = s.tokens.keys { $0.isScreen }
            guard !onScreen.isEmpty else { return [] }
            let items = onScreen.map { (key: $0, meta: s.tokens.meta(of: $0)!) }
            for k in onScreen { s.tokens.move(k, to: .carried) }
            for (k, c) in env.grid.cleanUp(items, by: order) { s.tokens.move(k, to: c.location, grid: env.grid) }
            s.monitor.page = min(s.monitor.page, s.pageCount(grid: env.grid) - 1)
            return [.persist, .wakeLoop]

        case let .drawerSettled(id, p):
            guard id.isDrawer, p.isFinite else { return [] }
            let opening = min(max(p, 0), id.spec.travel ?? p)
            guard s.drawers[id]?.p != opening else { return [] }
            s.drawers[id] = DrawerState(p: opening)
            return [.persist, .wakeLoop]

        case .phoneFlip:
            s.phone.faceDown.toggle()
            return [.persist, .wakeLoop]

        case let .cupState(cup):
            guard cup.pos.isFinite, cup != s.penCup else { return [] }
            s.penCup = cup
            return [.persist, .wakeLoop]

        case let .basketState(basket):
            guard basket != s.wastebasket else { return [] }
            s.wastebasket = basket
            return [.persist, .wakeLoop]

        case let .matSettled(mat):
            guard mat.isFinite, mat != s.mat else { return [] }
            s.mat = mat
            return [.persist, .wakeLoop]

        case let .pilesSettled(positions):
            return setPiles(&s, positions) ? [.persist, .wakeLoop] : []

        case let .chair(x, facing):
            let chair = ChairState(x: x, facing: facing)
            guard x.isFinite, chair != s.chair else { return [] }
            s.chair = chair
            return [.persist, .wakeLoop]

        case let .lights(lights):
            return reduceLights(&s, lights)

        case let .takeAllOut(id):
            let keys = id.map { s.tokens.members(of: $0) }
                ?? s.tokens.keys { if case .floor = $0 { true } else { $0.pile != nil } }
            let moved = parade(&s, keys, grid: env.grid)
            return moved.isEmpty ? [] : [.play(.parade, .tokens(moved)), .persist, .wakeLoop]

        case .takeEverythingOut:
            var effects: [Effect] = s.monitor.power == .off ? [.play(.crtOn, .monitor)] : []
            let moved = parade(&s, s.tokens.keys { !$0.isScreen }, grid: env.grid)
            s.monitor.power = .on
            s.monitor.av = false
            s.monitor.pendingNew = 0
            if let first = moved.first, let c = s.tokens.location(of: first)?.cell { s.monitor.page = c.page }
            if !moved.isEmpty { effects.append(.play(.parade, .tokens(moved))) }
            return effects + [.persist, .wakeLoop]

        case let .showOnDesk(key):
            return showOnDesk(&s, s.currentKey(for: key))

        case let .registerHints(names):
            Placement.register(names, into: &s.hints, now: env.now)
            return []

        case .clearDesk:
            return reduceClearDesk(&s, env)

        case .undo, .redo:
            // Journaled by `reduce(_:journal:_:_:)`.
            return []

        case .requestConnect:
            guard s.access != .connected else { return [] }
            s.access = .connecting
            return [.connectDesktop, .wakeLoop]

        case let .requestOpen(keys):
            let urls = keys.compactMap { s.url(of: s.currentKey(for: $0)) }
            return urls.isEmpty ? [] : [.open(urls)]

        case let .requestQuickLook(keys):
            let urls = keys.compactMap { s.url(of: s.currentKey(for: $0)) }
            return urls.isEmpty ? [] : [.quickLook(urls)]

        case let .requestReveal(keys):
            let urls = keys.compactMap { s.url(of: s.currentKey(for: $0)) }
            return urls.isEmpty ? [] : [.reveal(urls)]

        case let .requestCopy(keys):
            let urls = keys.compactMap { s.url(of: s.currentKey(for: $0)) }
            return urls.isEmpty ? [] : [.copy(urls)]

        case .requestTrash, .requestEmptyWastebasket, .requestEject, .importDropped:
            // MARK: files
            return reduceFiles(&s, a, env)

        case .requestPrivacySettings:
            return [.openPrivacySettings]

        case .requestChooseFolder:
            return [.chooseFolder]

        case let .clock(now):
            return Placement.expire(&s, now: now) > 0 ? [.persist] : []

        // MARK: containers (M6)
        case .openContainer, .closeContainer, .phoneFace:
            return reduceContainer(&s, a)
        // MARK: physics
        case .dropOnDesk, .dropOnFloor, .tipOver, .standUp:
            return reducePhysics(&s, a, env)
        // MARK: mat
        case .mat, .brushSettled, .tuckUnderMat:
            return reduceMat(&s, a, env)
        // MARK: files
        case .fileResult, .requestDropIn, .requestOpenVolume, .requestRevealVolume, .fileStarted:
            return reduceFiles(&s, a, env)
        }
    }

    // MARK: Snapshot

    private static func applySnapshot(_ s: inout DeskState, _ snapshot: DesktopSnapshot, now: Date, grid: ScreenGrid) -> [Effect] {
        let wasAccess = s.access
        let events = Reconciler.reconcile(&s, snapshot, now: now, grid: grid)
        s.access = .connected
        guard !events.isEmpty || wasAccess != .connected else { return [] }
        // Metadata-only changes (a growing download, an iCloud status flip) are saved with the next real change
        // or on quit, not on their own.
        let layoutChanged = wasAccess != .connected || events.contains { if case .updated = $0 { false } else { true } }

        var effects: [Effect] = []
        var printIn: [TokenKey] = []
        var arrivedWhileOff = 0
        for event in events {
            switch event {
            case let .added(key, loc, arrival):
                guard arrival != .safeSave else { continue }
                if loc.isScreen && s.monitor.power == .off {
                    arrivedWhileOff += 1
                } else {
                    printIn.append(key)
                }
            case let .removed(_, loc, _):
                if let id = loc.container {
                    effects.append(.play(.handleWiggle, .container(id)))
                } else {
                    effects.append(.play(.poof, .location(loc)))
                }
            default:
                break
            }
        }
        if !printIn.isEmpty { effects.append(.play(.printIn, .tokens(printIn))) }
        if arrivedWhileOff > 0 {
            s.monitor.pendingNew += arrivedWhileOff
            effects.append(.play(.ledAmber, .monitor))
        }
        effects += layoutChanged ? [.persist, .wakeLoop] : [.wakeLoop]
        return effects
    }

    // MARK: Moves

    /// Moves `keys` to `target`, in order. Several tokens pour into the cells nearest a screen target, stack
    /// in order into a container or pile, or spread along the floor. A single token dropped on an occupied
    /// cell swaps with its occupant when it came from another cell. A container that cannot take them all
    /// refuses the whole move (bonk).
    private static func move(_ s: inout DeskState, _ keys: [TokenKey], to target: Location, grid: ScreenGrid) -> [Effect] {
        var seen = Set<TokenKey>()
        let movers = keys.filter { s.tokens.contains($0) && seen.insert($0).inserted }
        guard !movers.isEmpty else { return [] }

        if case let .container(id, _) = target {
            let staying = s.tokens.members(of: id).filter { !seen.contains($0) }.count
            guard staying + movers.count <= id.spec.hardCap else {
                return [.play(.bonk, .container(id)), .toast(.containerFull)]
            }
        }
        let before = movers.map { s.tokens.location(of: $0)! }

        // Single-token swap on the screen.
        if movers.count == 1, let to = target.cell, let from = before[0].cell, grid.contains(to),
           let occupant = s.tokens.occupant(of: to), occupant != movers[0]
        {
            s.tokens.move(movers[0], to: .carried)
            s.tokens.move(occupant, to: from.location, grid: grid)
            s.tokens.move(movers[0], to: to.location, grid: grid)
            return [.persist, .wakeLoop]
        }

        for k in movers { s.tokens.move(k, to: .carried) }
        switch target {
        case let .screen(page, col, row):
            let aim = ScreenCell(page: page, col: col, row: row)
            var occupied = s.tokens.occupiedCells
            for k in movers {
                let c = grid.nearestFree(to: aim, occupied)
                occupied.insert(c)
                s.tokens.move(k, to: c.location, grid: grid)
            }
        case let .container(id, order):
            let start = min(max(order, 0), s.tokens.count(in: id))
            for (i, k) in movers.enumerated() { s.tokens.move(k, to: .container(id, order: start + i), grid: grid) }
        case let .desk(pile, order):
            if s.piles[pile] == nil { s.piles[pile] = Placement.defaultPilePos }
            let start = min(max(order, 0), s.tokens.members(of: pile).count)
            for (i, k) in movers.enumerated() { s.tokens.move(k, to: .desk(pile: pile, order: start + i), grid: grid) }
        case let .floor(x):
            let others = s.tokens.keys { if case .floor = $0 { true } else { false } }.filter { !seen.contains($0) }
                .compactMap { k -> Int? in if case let .floor(x)? = s.tokens.location(of: k) { x } else { nil } }
            let spots = floorSpots(near: x, count: movers.count, basket: s.wastebasket, occupied: others)
            for (k, spot) in zip(movers, spots) { s.tokens.move(k, to: .floor(x: spot)) }
        case .carried:
            break
        }
        Placement.pruneEmptyPiles(&s)
        s.monitor.page = min(s.monitor.page, s.pageCount(grid: grid) - 1)

        let after = movers.map { s.tokens.location(of: $0)! }
        return after == before ? [] : [.persist, .wakeLoop]
    }

    /// Sends `keys` to the first free monitor cells (from HDMI 1) in name order; returns them in that order.
    private static func parade(_ s: inout DeskState, _ keys: [TokenKey], grid: ScreenGrid) -> [TokenKey] {
        let ordered = Placement.byName(keys, in: s.tokens)
        for k in ordered { s.tokens.move(k, to: .carried) }
        var allocator = ScreenGrid.Allocator(grid: grid, occupied: s.tokens.occupiedCells)
        for k in ordered { s.tokens.move(k, to: allocator.next().location, grid: grid) }
        Placement.pruneEmptyPiles(&s)
        return ordered
    }

    private static func setPiles(_ s: inout DeskState, _ positions: [PileID: SIMD2<Float>]) -> Bool {
        var changed = false
        for (pile, pos) in positions where pos.isFinite && !s.tokens.members(of: pile).isEmpty && s.piles[pile] != pos {
            s.piles[pile] = pos
            changed = true
        }
        return changed
    }

    /// Find / Inventory ▸ Show on Desk: power on, then reveal the token where it lives and pulse it.
    private static func showOnDesk(_ s: inout DeskState, _ key: TokenKey) -> [Effect] {
        guard let loc = s.tokens.location(of: key) else { return [] }
        var effects: [Effect] = []
        if s.monitor.power == .off {
            s.monitor.power = .on
            s.monitor.pendingNew = 0
            effects.append(.play(.crtOn, .monitor))
        }
        switch loc {
        case let .screen(page, _, _):
            s.monitor.av = false
            s.monitor.page = page
        case let .container(id, _):
            revealContainer(&s, id)
        case .desk:
            effects.append(.play(.peekMat, .location(loc)))
        case .floor, .carried:
            break
        }
        effects += [.play(.pulse, .token(key)), .persist, .wakeLoop]
        return effects
    }
}
