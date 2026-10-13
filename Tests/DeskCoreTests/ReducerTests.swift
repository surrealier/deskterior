import Foundation
import Testing
@testable import DeskCore

@Suite("Reducer")
struct ReducerTests {
    typealias F = ModelFixture
    let env = ReduceEnv(now: ModelFixture.t0)

    func cell(_ page: Int, _ col: Int, _ row: Int) -> Location { .screen(page: page, col: col, row: row) }

    // MARK: Mirror actions

    @Test("snapshot: reconciles, connects, prints new files in, persists")
    func snapshot() {
        var s = DeskState()
        let effects = reduce(&s, .snapshot(F.snapshot([F.entry("b.txt", 2), F.entry("a.txt", 1)]), now: F.t0), env)
        #expect(s.access == .connected)
        #expect(effects == [.play(.printIn, .tokens([F.key(1), F.key(2)])), .persist, .wakeLoop])
        #expect(reduce(&s, .snapshot(F.snapshot([F.entry("b.txt", 2), F.entry("a.txt", 1)]), now: F.t0), env).isEmpty)
    }

    @Test("snapshot: files arriving while the monitor is off raise the amber badge")
    func snapshotWhileOff() {
        var s = F.mirrored(["a.txt"])
        s.monitor.power = .off
        let effects = reduce(&s, .snapshot(F.snapshot([F.entry("a.txt", 1), F.entry("b.txt", 2), F.entry("c.txt", 3)]), now: F.t0), env)
        #expect(s.monitor.pendingNew == 2)
        #expect(effects == [.play(.ledAmber, .monitor), .persist, .wakeLoop])
    }

    @Test("snapshot: removals poof on the screen and wiggle a container handle")
    func snapshotRemovals() {
        var s = F.mirrored(["a.txt", "b.txt"])
        s.tokens.move(F.key(2), to: .container(.riserLeft, order: 0))
        let effects = reduce(&s, .snapshot(F.snapshot([]), now: F.t0), env)
        #expect(effects == [
            .play(.poof, .location(cell(0, 0, 0))), .play(.handleWiggle, .container(.riserLeft)), .persist, .wakeLoop,
        ])
    }

    @Test("volumes: stored, and only a change wakes the scene")
    func volumes() {
        var s = DeskState()
        let v = [VolumeEntry(id: "U", name: "Stick", path: "/Volumes/Stick", kind: .removable, isEjectable: true)]
        #expect(reduce(&s, .volumes(v), env) == [.wakeLoop])
        #expect(s.volumes == v)
        #expect(reduce(&s, .volumes(v), env).isEmpty)
    }

    @Test("access: denied shows NO SIGNAL, granted reconnects, Finder-hidden asks first")
    func access() {
        var s = DeskState()
        #expect(reduce(&s, .finderHidesItems, env) == [.wakeLoop])
        #expect(s.access == .finderHidden)
        #expect(reduce(&s, .accessDenied, env) == [.toast(.accessDenied), .wakeLoop])
        #expect(s.access == .denied)
        #expect(reduce(&s, .finderHidesItems, env).isEmpty)
        #expect(reduce(&s, .accessGranted, env) == [.wakeLoop])
        #expect(s.access == .connecting)
    }

    @Test("requestConnect: starts mirroring once")
    func requestConnect() {
        var s = DeskState()
        #expect(reduce(&s, .requestConnect, env) == [.connectDesktop, .wakeLoop])
        #expect(s.access == .connecting)
        s.access = .connected
        #expect(reduce(&s, .requestConnect, env).isEmpty)
    }

    // MARK: Moves

    @Test("move: into a container in order; later moves insert at their order")
    func moveToContainer() {
        var s = F.mirrored(["a", "b", "c"])
        #expect(reduce(&s, .move([F.key(1), F.key(2)], to: .container(.cabinetMiddle, order: 0)), env) == [.persist, .wakeLoop])
        #expect(s.tokens.members(of: .cabinetMiddle) == [F.key(1), F.key(2)])
        _ = reduce(&s, .move([F.key(3)], to: .container(.cabinetMiddle, order: 1)), env)
        #expect(s.tokens.members(of: .cabinetMiddle) == [F.key(1), F.key(3), F.key(2)])
        #expect(s.tokens.location(of: F.key(2)) == .container(.cabinetMiddle, order: 2))
        #expect(s.violations().isEmpty)
    }

    @Test("move: a container past its hard cap bonks and changes nothing")
    func moveBonksAtHardCap() {
        var s = F.mirrored((1...8).map { "f\($0)" })
        _ = reduce(&s, .move((1...5).map { F.key(UInt64($0)) }, to: .container(.penCup, order: 0)), env)
        let before = s
        let effects = reduce(&s, .move([F.key(6), F.key(7)], to: .container(.penCup, order: 0)), env)
        #expect(effects == [.play(.bonk, .container(.penCup)), .toast(.containerFull)])
        #expect(s == before)
        // Reordering inside a full container is fine.
        _ = reduce(&s, .move([F.key(6)], to: .container(.penCup, order: 0)), env)
        #expect(s.tokens.count(in: .penCup) == 6)
        #expect(reduce(&s, .move([F.key(1)], to: .container(.penCup, order: 5)), env) == [.persist, .wakeLoop])
        #expect(s.tokens.members(of: .penCup).last == F.key(1))
    }

    @Test("move: one token onto another's cell swaps them")
    func moveSwaps() {
        var s = F.mirrored(["a", "b"])
        _ = reduce(&s, .move([F.key(1)], to: cell(0, 1, 0)), env)
        #expect(s.tokens.location(of: F.key(1)) == cell(0, 1, 0))
        #expect(s.tokens.location(of: F.key(2)) == cell(0, 0, 0))
    }

    @Test("move: several tokens pour into the cells nearest the target")
    func movePours() {
        var s = F.mirrored(["a", "b", "c", "d"])
        _ = reduce(&s, .move([F.key(1), F.key(2), F.key(3)], to: cell(0, 4, 2)), env)
        #expect(s.tokens.location(of: F.key(1)) == cell(0, 4, 2))
        #expect(s.tokens.location(of: F.key(2)) == cell(0, 4, 1))
        #expect(s.tokens.location(of: F.key(3)) == cell(0, 3, 2))
        #expect(s.violations().isEmpty)
    }

    @Test("move: piles are created on demand and forgotten when empty; the floor spreads tokens")
    func movePilesAndFloor() {
        var s = F.mirrored(["a", "b"])
        _ = reduce(&s, .move([F.key(1), F.key(2)], to: .desk(pile: "P3", order: 0)), env)
        #expect(s.piles[PileID("P3")] == Placement.defaultPilePos)
        #expect(s.tokens.members(of: PileID("P3")) == [F.key(1), F.key(2)])
        _ = reduce(&s, .move([F.key(1), F.key(2)], to: .floor(x: 100)), env)
        #expect(s.piles.isEmpty)
        #expect(s.tokens.location(of: F.key(1)) == .floor(x: 100))
        #expect(s.tokens.location(of: F.key(2)) == .floor(x: 100 + Placement.floorSpacing))
        #expect(s.violations().isEmpty)
    }

    @Test("move: unknown keys and no-op moves emit nothing")
    func moveNoOp() {
        var s = F.mirrored(["a"])
        #expect(reduce(&s, .move([F.key(99)], to: .floor(x: 1)), env).isEmpty)
        #expect(reduce(&s, .move([F.key(1)], to: cell(0, 0, 0)), env).isEmpty)
    }

    @Test("settle: applies scene landings and pile positions")
    func settle() {
        var s = F.mirrored(["a", "b"])
        _ = reduce(&s, .move([F.key(1)], to: .desk(pile: "P1", order: 0)), env)
        let report = SettleReport(moves: [.init(key: F.key(2), to: .container(.wastebasket, order: 0))], piles: ["P1": [300, 20]])
        #expect(reduce(&s, .settle(report), env) == [.persist, .wakeLoop])
        #expect(s.tokens.location(of: F.key(2)) == .container(.wastebasket, order: 0))
        #expect(s.piles[PileID("P1")] == [300, 20])
    }

    // MARK: Monitor

    @Test("power: off and on; turning on clears the badge")
    func power() {
        var s = F.mirrored(["a"])
        #expect(reduce(&s, .power(false), env) == [.play(.crtOff, .monitor), .persist, .wakeLoop])
        s.monitor.pendingNew = 3
        #expect(reduce(&s, .power(false), env).isEmpty)
        #expect(reduce(&s, .power(true), env) == [.play(.crtOn, .monitor), .persist, .wakeLoop])
        #expect(s.monitor.power == .on && s.monitor.pendingNew == 0)
    }

    @Test("setPage: clamps to the pages in use and leaves AV")
    func setPage() {
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot((0..<50).map { F.entry("f\($0)", UInt64($0 + 1)) }), now: F.t0)
        #expect(reduce(&s, .setPage(1), env) == [.play(.staticNoise, .monitor), .play(.osd, .monitor), .persist, .wakeLoop])
        #expect(s.monitor.page == 1)
        _ = reduce(&s, .setPage(9), env)
        #expect(s.monitor.page == 1)
        #expect(reduce(&s, .setPage(1), env).isEmpty)
        s.monitor.av = true
        _ = reduce(&s, .setPage(0), env)
        #expect(s.monitor.page == 0 && !s.monitor.av)
    }

    @Test("cycleInput: HDMI 1…n, then AV, then HDMI 1")
    func cycleInput() {
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot((0..<50).map { F.entry("f\($0)", UInt64($0 + 1)) }), now: F.t0)
        var seen: [String] = []
        for _ in 0..<4 {
            _ = reduce(&s, .cycleInput, env)
            seen.append(s.monitor.av ? "AV" : "HDMI \(s.monitor.page + 1)")
        }
        #expect(seen == ["HDMI 2", "AV", "HDMI 1", "HDMI 2"])
    }

    @Test("selectAV: switches to the empty AV input once; setPage leaves it")
    func selectAV() {
        var s = F.mirrored(["a"])
        #expect(reduce(&s, .selectAV, env) == [.play(.staticNoise, .monitor), .play(.osd, .monitor), .persist, .wakeLoop])
        #expect(s.monitor.av && Visibility.of(s.tokens.location(of: F.key(1))!, s).appearance == .notShown)
        #expect(reduce(&s, .selectAV, env).isEmpty)
        _ = reduce(&s, .setPage(0), env)
        #expect(!s.monitor.av)
    }

    @Test("clearDesk: a toast until the M9 plan; plain reduce ignores undo and redo")
    func clearDeskStub() {
        var s = F.mirrored(["a"])
        let before = s
        #expect(reduce(&s, .clearDesk, env) == [.toast(.notYetAvailable)])
        #expect(reduce(&s, .undo, env).isEmpty && reduce(&s, .redo, env).isEmpty)
        #expect(s == before)
    }

    @Test("cleanUp: repacks the screen tokens from HDMI 1 in the chosen order")
    func cleanUp() {
        var s = F.mirrored(["c", "a", "b"])
        _ = reduce(&s, .move([F.key(2)], to: cell(2, 8, 4)), env)
        #expect(s.pageCount() == 3)
        #expect(reduce(&s, .cleanUp(.name), env) == [.persist, .wakeLoop])
        #expect(s.tokens.location(of: F.key(2)) == cell(0, 0, 0))
        #expect(s.tokens.location(of: F.key(3)) == cell(0, 1, 0))
        #expect(s.tokens.location(of: F.key(1)) == cell(0, 2, 0))
        #expect(s.pageCount() == 1)
    }

    // MARK: Element settles

    @Test("drawerSettled, phoneFlip, cupState, basketState, matSettled, pilesSettled, chair, lights store state")
    func elementSettles() {
        var s = F.mirrored(["a"])
        #expect(reduce(&s, .drawerSettled(.cabinetTop, 7), env) == [.persist, .wakeLoop])
        #expect(s.drawerOpening(.cabinetTop) == 7)
        #expect(reduce(&s, .drawerSettled(.penCup, 3), env).isEmpty)
        #expect(reduce(&s, .phoneFlip, env) == [.persist, .wakeLoop])
        #expect(s.phone.faceDown)
        _ = reduce(&s, .cupState(PenCupState(state: "lying", pos: [1, 2])), env)
        #expect(s.penCup.state == "lying")
        _ = reduce(&s, .basketState(BasketState(state: "tipped", swishes: 3)), env)
        #expect(s.wastebasket.swishes == 3)
        var mat = MatState()
        mat.angle = 0.25
        _ = reduce(&s, .matSettled(mat), env)
        #expect(s.mat.angle == 0.25)
        _ = reduce(&s, .chair(310, 2), env)
        #expect(s.chair == ChairState(x: 310, facing: 2))
        _ = reduce(&s, .lights(LightsState(mode: .lampOnly, room: false, lamp: true)), env)
        #expect(s.lights.mode == .lampOnly)
        // Positions for piles that do not exist are ignored.
        #expect(reduce(&s, .pilesSettled(["P9": [1, 1]]), env).isEmpty)
        _ = reduce(&s, .move([F.key(1)], to: .desk(pile: "P1", order: 0)), env)
        #expect(reduce(&s, .pilesSettled(["P1": [9, 9]]), env) == [.persist, .wakeLoop])
        #expect(s.piles[PileID("P1")] == [9, 9])
    }

    @Test("Non-finite numbers from the scene are refused, so the layout always encodes")
    func nonFiniteRefused() throws {
        var s = F.mirrored(["a"])
        _ = reduce(&s, .move([F.key(1)], to: .desk(pile: "P1", order: 0)), env)
        for bad in [Float.nan, .infinity, -.infinity] {
            #expect(reduce(&s, .drawerSettled(.riserLeft, bad), env).isEmpty)
            #expect(reduce(&s, .cupState(PenCupState(state: "lying", pos: [bad, 1])), env).isEmpty)
            var mat = MatState()
            mat.angle = bad
            #expect(reduce(&s, .matSettled(mat), env).isEmpty)
            #expect(reduce(&s, .pilesSettled(["P1": [1, bad]]), env).isEmpty)
            #expect(reduce(&s, .settle(SettleReport(piles: ["P1": [bad, 0]])), env).isEmpty)
            #expect(reduce(&s, .chair(bad, 1), env).isEmpty)
        }
        // Openings are clamped to the drawer's travel.
        _ = reduce(&s, .drawerSettled(.riserLeft, 99), env)
        #expect(s.drawerOpening(.riserLeft) == 10)
        _ = try DeskDocument(state: s, savedAt: F.t0).encoded()
    }

    @Test("snapshot: metadata-only changes wake the scene but do not save")
    func metadataOnlyDoesNotPersist() {
        var s = F.mirrored(["a.txt"])
        var grown = F.entry("a.txt", 1)
        grown.meta.size = 5000
        #expect(reduce(&s, .snapshot(F.snapshot([grown]), now: F.t0), env) == [.wakeLoop])
        #expect(s.tokens.meta(of: F.key(1))?.size == 5000)
        let renamed = F.entry("b.txt", 1)
        #expect(reduce(&s, .snapshot(F.snapshot([renamed]), now: F.t0), env) == [.persist, .wakeLoop])
    }

    // MARK: Take out

    @Test("takeAllOut: a container's tokens parade to the first free cells in name order")
    func takeAllOutContainer() {
        var s = F.mirrored(["x", "b", "a", "c"])
        _ = reduce(&s, .move([F.key(2), F.key(3), F.key(4)], to: .container(.riserCubby, order: 0)), env)
        let effects = reduce(&s, .takeAllOut(.riserCubby), env)
        #expect(effects == [.play(.parade, .tokens([F.key(3), F.key(2), F.key(4)])), .persist, .wakeLoop])
        // "x" keeps (3,0); the three fill the free cells before it.
        #expect(s.tokens.location(of: F.key(1)) == cell(0, 3, 0))
        #expect(s.tokens.location(of: F.key(3)) == cell(0, 0, 0))
        #expect(s.tokens.location(of: F.key(2)) == cell(0, 1, 0))
        #expect(s.tokens.location(of: F.key(4)) == cell(0, 2, 0))
        #expect(reduce(&s, .takeAllOut(.riserCubby), env).isEmpty)
    }

    @Test("takeAllOut(nil): loose desk piles and floor tokens come back")
    func takeAllOutLoose() {
        var s = F.mirrored(["a", "b", "c"])
        _ = reduce(&s, .move([F.key(1)], to: .desk(pile: "P1", order: 0)), env)
        _ = reduce(&s, .move([F.key(2)], to: .floor(x: 40)), env)
        _ = reduce(&s, .move([F.key(3)], to: .container(.phone, order: 0)), env)
        _ = reduce(&s, .takeAllOut(nil), env)
        #expect(s.tokens.location(of: F.key(1))?.isScreen == true)
        #expect(s.tokens.location(of: F.key(2))?.isScreen == true)
        #expect(s.tokens.location(of: F.key(3)) == .container(.phone, order: 0))
        #expect(s.piles.isEmpty)
    }

    @Test("takeEverythingOut: every hidden token returns, the monitor powers on at the first page used")
    func takeEverythingOut() {
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot((0..<46).map { F.entry(String(format: "f%02d", $0), UInt64($0 + 1)) }), now: F.t0)
        _ = reduce(&s, .move([F.key(46)], to: .container(.cabinetFile, order: 0)), env)
        _ = reduce(&s, .move([F.key(1)], to: .container(.wastebasket, order: 0)), env)
        _ = reduce(&s, .power(false), env)
        s.monitor.av = true
        let effects = reduce(&s, .takeEverythingOut, env)
        #expect(effects == [.play(.crtOn, .monitor), .play(.parade, .tokens([F.key(1), F.key(46)])), .persist, .wakeLoop])
        #expect(s.monitor.power == .on && !s.monitor.av)
        #expect(s.tokens.keys { !$0.isScreen }.isEmpty)
        #expect(s.tokens.location(of: F.key(1)) == cell(0, 0, 0))
        #expect(s.monitor.page == 0)
        #expect(s.violations().isEmpty)
    }

    // MARK: Show on Desk

    @Test("showOnDesk: powers on and switches to the token's page")
    func showOnDeskScreen() {
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot((0..<50).map { F.entry(String(format: "f%02d", $0), UInt64($0 + 1)) }), now: F.t0)
        _ = reduce(&s, .power(false), env)
        let effects = reduce(&s, .showOnDesk(F.key(50)), env)
        #expect(effects == [.play(.crtOn, .monitor), .play(.pulse, .token(F.key(50))), .persist, .wakeLoop])
        #expect(s.monitor.page == 1 && s.monitor.power == .on)
    }

    @Test("showOnDesk: opens the drawer, flips the phone up, peeks the mat")
    func showOnDeskHidden() {
        var s = F.mirrored(["a", "b", "c"])
        _ = reduce(&s, .move([F.key(1)], to: .container(.cabinetMiddle, order: 0)), env)
        _ = reduce(&s, .move([F.key(2)], to: .container(.phone, order: 0)), env)
        _ = reduce(&s, .move([F.key(3)], to: .desk(pile: "P1", order: 0)), env)
        s.phone.faceDown = true
        _ = reduce(&s, .showOnDesk(F.key(1)), env)
        #expect(s.drawerOpening(.cabinetMiddle) == 14)
        #expect(Visibility.of(s.tokens.location(of: F.key(1))!, s).appearance == .mini)
        _ = reduce(&s, .showOnDesk(F.key(2)), env)
        #expect(!s.phone.faceDown)
        let effects = reduce(&s, .showOnDesk(F.key(3)), env)
        #expect(effects.first == .play(.peekMat, .location(.desk(pile: "P1", order: 0))))
        #expect(reduce(&s, .showOnDesk(F.key(99)), env).isEmpty)
    }

    // MARK: Requests and the file-effect rule

    @Test("Open, Quick Look, Reveal and Copy produce file URLs under the root")
    func requests() {
        var s = F.mirrored(["a.txt", "Folder"])
        s.tokens.updateMeta(F.key(2), TokenMeta(name: "Folder", kind: .folder))
        let a = URL(fileURLWithPath: "/fake/Desktop/a.txt")
        let folder = URL(fileURLWithPath: "/fake/Desktop/Folder", isDirectory: true)
        #expect(reduce(&s, .requestOpen([F.key(1), F.key(2), F.key(9)]), env) == [.open([a, folder])])
        #expect(reduce(&s, .requestQuickLook([F.key(1)]), env) == [.quickLook([a])])
        #expect(reduce(&s, .requestReveal([F.key(1)]), env) == [.reveal([a])])
        #expect(reduce(&s, .requestCopy([F.key(1)]), env) == [.copy([a])])
        #expect(reduce(&s, .requestOpen([F.key(9)]), env).isEmpty)
        #expect(reduce(&s, .requestPrivacySettings, env) == [.openPrivacySettings])
        #expect(reduce(&s, .requestChooseFolder, env) == [.chooseFolder])
    }

    @Test("registerHints and clock: hints and tombstones expire on the clock")
    func hintsAndClock() {
        var s = F.mirrored(["a", "b"])
        #expect(reduce(&s, .registerHints(["x.png": .floor(x: 3)]), env).isEmpty)
        #expect(s.hints.count == 1)
        Reconciler.reconcile(&s, F.snapshot([F.entry("a", 1)]), now: F.t0)
        #expect(s.tombstones.count == 1)
        #expect(reduce(&s, .clock(F.t0.addingTimeInterval(20)), env).isEmpty)
        #expect(s.hints.isEmpty && s.tombstones.count == 1)
        #expect(reduce(&s, .clock(F.t0.addingTimeInterval(8 * 24 * 3600)), env) == [.persist])
        #expect(s.tombstones.isEmpty)
    }

    /// One of every action, against a populated state.
    static func catalogue() -> [DeskAction] {
        let k = [F.key(1), F.key(2)]
        return [
            .snapshot(F.snapshot([F.entry("a", 1), F.entry("n", 9)]), now: F.t0), .volumes([]), .accessDenied,
            .accessGranted, .finderHidesItems, .move(k, to: .container(.riserLeft, order: 0)), .settle(SettleReport()),
            .power(false), .power(true), .setPage(0), .cycleInput, .selectAV, .cleanUp(.kind), .drawerSettled(.riserLeft, 10),
            .phoneFlip, .cupState(PenCupState()), .basketState(BasketState()), .matSettled(MatState()),
            .pilesSettled([:]), .chair(1, 1), .lights(LightsState()), .takeAllOut(.riserLeft), .takeAllOut(nil),
            .takeEverythingOut, .clearDesk, .showOnDesk(F.key(1)), .undo, .redo, .registerHints(["z": .floor(x: 0)]),
            .requestConnect, .requestOpen(k), .requestQuickLook(k), .requestReveal(k), .requestCopy(k), .requestTrash(k),
            .requestEmptyWastebasket, .requestEject("U"), .importDropped([URL(fileURLWithPath: "/tmp/x")], at: .floor(x: 0), op: .copy),
            .requestPrivacySettings, .requestChooseFolder, .clock(F.t0),
        ]
    }

    @Test("Only request actions emit file effects, and nothing changes files before M11")
    func fileEffectRule() {
        for action in Self.catalogue() {
            var s = F.mirrored(["a", "b", "c"])
            let effects = reduce(&s, action, env)
            let touches = effects.contains { $0.touchesFiles }
            let mutates = effects.contains { $0.mutatesFiles }
            if !action.isRequest {
                #expect(!touches, "\(action) emitted \(effects)")
            }
            #expect(!mutates, "\(action) emitted \(effects)")
            #expect(s.violations().isEmpty, "\(action) broke an invariant")
        }
    }

    @Test("Every live token keeps exactly one valid location under random moves")
    func invariantProperty() {
        var s = DeskState()
        Reconciler.reconcile(&s, F.snapshot((0..<60).map { F.entry("t\($0)", UInt64($0 + 1)) }), now: F.t0)
        var rng = SplitMix64(seed: 42)
        let piles: [PileID] = ["P1", "P2", "P3"]
        for step in 0..<3000 {
            let count = 1 + rng.nextInt(below: 4)
            let keys = (0..<count).map { _ in F.key(UInt64(1 + rng.nextInt(below: 60))) }
            let target: Location = switch rng.nextInt(below: 6) {
            case 0: .screen(page: rng.nextInt(below: 3), col: rng.nextInt(below: 9), row: rng.nextInt(below: 5))
            case 1, 2: .container(ContainerID.allCases[rng.nextInt(below: ContainerID.allCases.count)], order: rng.nextInt(below: 30) - 2)
            case 3: .desk(pile: piles[rng.nextInt(below: piles.count)], order: rng.nextInt(below: 6))
            case 4: .floor(x: rng.nextInt(below: 500))
            default: .screen(page: 0, col: rng.nextInt(below: 9), row: rng.nextInt(below: 5))
            }
            let action: DeskAction = switch rng.nextInt(below: 10) {
            case 0: .takeAllOut(ContainerID.allCases[rng.nextInt(below: ContainerID.allCases.count)])
            case 1: .cleanUp(.name)
            default: .move(keys, to: target)
            }
            _ = reduce(&s, action, env)
            #expect(s.tokens.count == 60)
            let problems = s.violations()
            #expect(problems.isEmpty, "step \(step) \(action): \(problems)")
            if !problems.isEmpty { break }
        }
        for id in ContainerID.allCases { #expect(s.tokens.count(in: id) <= id.spec.hardCap) }
    }
}
