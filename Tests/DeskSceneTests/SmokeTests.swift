import Testing
@testable import DeskScene
import DeskCore

@Test func moduleLinks() {
    #expect(ArtSpace.unitsPerPixel == 4)
    #expect(!DeskCore.version.isEmpty)
}
