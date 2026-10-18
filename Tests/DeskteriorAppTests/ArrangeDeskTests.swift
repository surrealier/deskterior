import DeskCore
import Foundation
import Testing
@testable import DeskteriorApp

/// The Arrange Desk window's rows (Erratum 30): every stowable object by group, its toggle, how many files it holds
/// and what putting it away does to them.
@Suite("Arrange Desk")
struct ArrangeDeskTests {
    /// A desk with `n` files in `container`.
    func desk(_ n: Int, in container: ContainerID) -> DeskState {
        var s = DeskState()
        for i in 0..<n {
            _ = s.tokens.insert(TokenKey(volume: "V", inode: UInt64(i + 1)), meta: TokenMeta(name: "f\(i).png", kind: .image),
                                at: .container(container, order: i))
        }
        return s
    }

    @Test("Rows follow StowCatalog's groups and order; everything is on the desk by default")
    func rows() {
        let model = ArrangeDeskModel(state: DeskState())
        #expect(model.rows(.storage).map(\.id) == [.riserDrawers, .cabinet])
        #expect(model.rows(.desk).map(\.id) == [.phoneStand, .plant])
        #expect(model.rows(.partition).map(\.id) == [.partition, .dailyPad, .memoClips, .clipLight, .dDayCard])
        #expect(model.rows(.wall).map(\.id) == [.wallShelf, .pegboard, .stringLights, .floorPlant, .wallArt])
        let all = StowSpec.Group.allCases.flatMap { model.rows($0) }
        #expect(all.count == StowID.allCases.count && all.allSatisfy { $0.isOn && $0.isEnabled && $0.caption == nil })
        #expect(ArrangeDeskModel.row(.cabinet, in: DeskState()).inside == 0, "a place that holds files says how many")
        #expect(ArrangeDeskModel.row(.plant, in: DeskState()).inside == nil, "the plant holds none")
        #expect(ArrangeDeskModel.row(.partition, in: DeskState()).inside == 0, "the partition holds the memo clips'")
        #expect(ArrangeDeskModel.row(.riserDrawers, in: DeskState()).title == "Riser Drawers")
    }

    @Test("A toggle switched off puts the object away; on brings it back; the footer brings everything back")
    func toggles() {
        let model = ArrangeDeskModel(state: DeskState())
        var sent: [String] = []
        model.dispatch = { sent.append("\($0)") }
        model.set(.cabinet, on: false)
        model.set(.cabinet, on: true)
        model.set(.dDayCard, on: false)
        model.bringEverythingBack()
        #expect(sent == ["putAway(DeskCore.StowID.cabinet)", "bringBack(DeskCore.StowID.cabinet)",
                         "putAway(DeskCore.StowID.dDayCard)", "bringBackAll"])
        #expect(!model.anythingAway)
        model.state.stowed = [.plant]
        #expect(model.anythingAway)
        #expect(ArrangeDeskModel.row(.plant, in: model.state).isOn == false)
    }

    @Test("Captions: the files a place would take out to the monitor; add-ons rest while the partition is away")
    func captions() {
        let cabinet = ArrangeDeskModel.row(.cabinet, in: desk(3, in: .cabinetMiddle))
        #expect(cabinet.inside == 3 && cabinet.caption == "Putting it away takes 3 files out to the monitor.")
        // The memo clips' files count for the partition too: putting it away takes them out.
        let clipped = desk(2, in: .memoClips)
        #expect(ArrangeDeskModel.row(.memoClips, in: clipped).inside == 2)
        #expect(ArrangeDeskModel.row(.partition, in: clipped).caption == "Putting it away takes 2 files out to the monitor.")
        var away = DeskState()
        away.stowed = [.partition, .clipLight]
        let pad = ArrangeDeskModel.row(.dailyPad, in: away), light = ArrangeDeskModel.row(.clipLight, in: away)
        #expect(!pad.isEnabled && pad.isOn && pad.caption == "Comes back with the partition.")
        #expect(!light.isEnabled && !light.isOn, "the add-on's own flag shows")
        let partition = ArrangeDeskModel.row(.partition, in: away)
        #expect(partition.isEnabled && !partition.isOn && partition.caption == nil)
    }

    @Test("The window speaks Korean when the app does")
    func korean() {
        let row = ArrangeDeskModel.row(.cabinet, in: desk(1, in: .cabinetTop), language: .ko)
        #expect(row.title == "서랍장" && row.caption == "넣어 두면 파일 1개를 모니터로 꺼내요.")
        #expect(ArrangeDeskModel.row(.dDayCard, in: DeskState(), language: .ko).title == "디데이 카드")
        var away = DeskState()
        away.stowed = [.partition]
        #expect(ArrangeDeskModel.row(.memoClips, in: away, language: .ko).caption == "파티션과 함께 돌아와요.")
        #expect(ArrangeDeskModel.title(.storage, language: .ko) == "수납" && ArrangeDeskModel.title(.wall, language: .ko) == "벽")
        #expect(L10n.format(.inside, [1], .ko) == "1개 들어 있음")
    }
}
