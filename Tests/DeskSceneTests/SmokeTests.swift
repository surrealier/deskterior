import Testing
@testable import DeskScene
import DeskCore

@Test func moduleLinks() {
    #expect(DeskSceneModule.coreVersion == DeskCore.version)
}
