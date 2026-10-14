import DeskCore
import DeskPixels

/// The room's side of the explicit file actions (M11; DESIGN §2.2 E15, §3.5–§3.6): the drive hub in the hub's slot,
/// the puff when the wastebasket loses a ball to the trash, where files dropped from outside would land, and the
/// hand-off of a carry to the system's drag when it leaves the window.
extension RoomContent {
    /// Builds and installs the drive hub (called once from `init`).
    func installFiles() {
        let hub = DriveHubElement(context: context, placed: { [unowned self] in elements.first { $0.id == "hub" } })
        install([hub], inSlotOf: "hub")
    }

    var driveHub: DriveHubElement? { extras.lazy.compactMap { $0 as? DriveHubElement }.first }

    /// File results' animations beside the ones other elements play (`play`); true when nothing else should run.
    /// A ball leaving the wastebasket for the trash puffs at its mouth (the heap shrinks with the model).
    func playFiles(_ id: AnimationID, _ target: AnimTarget) -> Bool {
        if id == .handleWiggle, case .container(.wastebasket) = target, let hub = context.physics {
            let mouth = hub.basket.mouthRect
            context.fx.puff(at: ArtPoint(mouth.midX, mouth.maxY))
            return true
        }
        return false
    }

    /// Where `count` files dropped from outside at canvas `p` land (DESIGN §3.6): whatever a carry of that many
    /// tokens released there would get (a screen cell, a hiding place, a pile — a new one at the desk-plane point
    /// under `p` — or a bonk), the floor below the desk, else the monitor's first free cell.
    func fileDropVerdict(count: Int, at p: SIMD2<Float>) -> FileDropVerdict {
        guard let s = context.state else { return .bonk(nil) }
        // Stand-ins for the files: only their number counts (capacities, pours).
        let keys = (0..<max(1, count)).map { TokenKey(volume: "drop-in", inode: UInt64($0) + 1) }
        let pixel = ArtPoint(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
        switch DropResolver.resolve(keys, at: pixel, elements: routing)?.verdict {
        case let .accept(.desk(pile, order))?:
            let pos = s.piles[pile] == nil ? context.physics?.plane(p) : nil
            return .land(.desk(pile: pile, order: order), pilePos: pos)
        case let .accept(location)?:
            return .land(location, pilePos: nil)
        case let .bonk(reason)?:
            return .bonk(reason)
        case nil:
            let core = ArtPoint(pixel.x - layout.coreOrigin.x, pixel.y - layout.coreOrigin.y)
            if core.y > CoreLayout.deskFrontY, core.y <= CoreLayout.floorY {
                return .land(.floor(x: min(max(core.x, FloorLine.centres.lowerBound), FloorLine.centres.upperBound)), pilePos: nil)
            }
            return .land(ScreenGrid.standard.firstFree(s.tokens.occupiedCells).location, pilePos: nil)
        }
    }
}

/// Where files dropped onto the desk from outside go (`DeskScene.fileDropVerdict`).
public enum FileDropVerdict: Sendable, Equatable {
    /// They come in and land here; `pilePos` places a new desk pile.
    case land(Location, pilePos: SIMD2<Float>?)
    /// Refused (the screen is off, a container is full, a drive): BONK, and the toast says why when there is one.
    case bonk(ToastKey?)
}

// MARK: - Scene access (the app's drag-out and drop-in, demos, tests)

extension DeskScene {
    /// Where `count` files dropped from outside at canvas `p` would go.
    public func fileDropVerdict(count: Int, at p: SIMD2<Float>) -> FileDropVerdict {
        room?.fileDropVerdict(count: count, at: p) ?? .bonk(nil)
    }

    /// Brackets the screen cell files dragged in from outside would land in (nil clears it).
    public func showFileDropTarget(count: Int, at p: SIMD2<Float>?) {
        guard let room else { return }
        if let p, case let .land(loc, _) = room.fileDropVerdict(count: count, at: p), let cell = loc.cell {
            room.screen.dropTarget = cell
        } else {
            room.screen.dropTarget = nil
        }
        room.screen.render()
    }

    /// A refused drop from outside: BONK where it was let go, a 1-px shake and the toast (as a carry's bonk).
    public func bonkFileDrop(at p: SIMD2<Float>, _ reason: ToastKey?) {
        guard let room else { return }
        room.context.fx.pop(.bonk, at: ArtPoint(Int(p.x), Int(p.y) - 4))
        room.context.shake(frames: 2)
        if let reason { room.showToast(reason) }
        room.context.bonks += 1
    }

    /// The tokens of the carry in hand, while one is being carried.
    public var carriedTokenKeys: [TokenKey]? {
        guard let carry = room?.router.drag as? CarrySession, carry.phase == .carrying else { return nil }
        return carry.keys
    }

    /// The carry in hand leaves the window (DESIGN §3.6 Drag-out): its stack goes and its tokens are home at once,
    /// as in Finder, while the system's drag takes the files on. Returns the carried tokens.
    @discardableResult
    public func handOffCarry() -> [TokenKey]? {
        guard let room, let carry = room.router.drag as? CarrySession, carry.phase == .carrying else { return nil }
        carry.finishNow()
        room.router.cancelAll()
        return carry.keys
    }

    /// Hides tokens whose files another app is taking (a drag-out's `.move` or `.delete`) until `revealDragOut`.
    public func holdForDragOut(_ keys: Set<TokenKey>) {
        guard let room, !keys.isEmpty else { return }
        room.screen.carried.formUnion(keys)
        room.screen.render()
    }

    /// Shows held tokens again (those whose files are still there).
    public func revealDragOut(_ keys: Set<TokenKey>) {
        guard let room, !keys.isEmpty else { return }
        let current = deskState.map { s in Set(keys.map(s.currentKey)) } ?? []
        room.screen.carried.subtract(keys.union(current))
        room.screen.render()
    }

    /// The icon a drag out of the desk shows: the lead token's 16-px icon.
    public func dragImage(for keys: [TokenKey]) -> PixelBuffer? {
        guard let room, let s = deskState, let key = keys.first, let meta = s.tokens.meta(of: key) else { return nil }
        return TokenArt.icon(key, meta, room.context)
    }

    /// The drive hub's live anchors (`hub.drive.<i>`, `hub.more`), else nil.
    public func fileAnchor(_ name: String) -> ArtRect? {
        room?.driveHub?.anchor(name)
    }

    /// Drives standing on the hub, and how many sit behind its "+n" tag.
    public var hubDrives: (shown: Int, more: Int) {
        guard let hub = room?.driveHub else { return (0, 0) }
        return (hub.shown.count, hub.more.count)
    }
}
