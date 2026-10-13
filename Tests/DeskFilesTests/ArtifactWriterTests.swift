import Foundation
import Testing
@testable import DeskFiles

/// Everything happens under `FileManager.temporaryDirectory/deskterior-tests-<uuid>` with a fake desktop folder;
/// the real desktop is never touched.
@Suite("DesktopLocator and ArtifactWriter")
struct ArtifactWriterTests {
    let root: URL
    let desk: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskterior-tests-\(UUID().uuidString)", isDirectory: true)
        desk = root.appendingPathComponent("FakeDesk", isDirectory: true)
        try FileManager.default.createDirectory(at: desk, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("The default desktop comes from FileManager")
    func defaultDesktop() {
        defer { cleanUp() }
        let url = DesktopLocator.defaultDesktopURL()
        #expect(url.isFileURL)
        #expect(url.lastPathComponent == "Desktop")
        #expect(url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @Test("Inside checks resolve dot-dot, symlinks, missing paths and case")
    func insideChecks() throws {
        defer { cleanUp() }
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link-to-desk")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: desk)

        #expect(DesktopLocator.isInsideDesktop(desk, desktop: desk))
        #expect(DesktopLocator.isInsideDesktop(desk.appendingPathComponent("a/b/c"), desktop: desk))
        #expect(DesktopLocator.isInsideDesktop(other.appendingPathComponent("../FakeDesk/x"), desktop: desk))
        #expect(DesktopLocator.isInsideDesktop(link.appendingPathComponent("snapshots"), desktop: desk))
        #expect(DesktopLocator.isInsideDesktop(root.appendingPathComponent("fakedesk/x"), desktop: desk))
        #expect(!DesktopLocator.isInsideDesktop(other, desktop: desk))
        #expect(!DesktopLocator.isInsideDesktop(root.appendingPathComponent("FakeDesk2/x"), desktop: desk))
        #expect(!DesktopLocator.isInsideDesktop(root, desktop: desk))
        // /tmp is a symlink to /private/tmp; both spellings resolve alike.
        #expect(DesktopLocator.canonicalPath(URL(fileURLWithPath: "/tmp/x/y")).hasPrefix("/private/tmp/"))
    }

    @Test("The writer refuses directories inside the desktop and creates nothing there")
    func refusesDesktop() throws {
        defer { cleanUp() }
        let link = root.appendingPathComponent("sneaky")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: desk)
        for target in [desk, desk.appendingPathComponent("out"), link.appendingPathComponent("out")] {
            #expect(throws: ArtifactWriter.Failure.insideDesktop(target.standardizedFileURL.path)) {
                try ArtifactWriter(directory: target, desktop: desk)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: desk.appendingPathComponent("out").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.path).isEmpty)
    }

    @Test("The writer creates its directory and writes atomically")
    func writes() throws {
        defer { cleanUp() }
        let dir = root.appendingPathComponent("snapshots/run-1", isDirectory: true)
        let writer = try ArtifactWriter(directory: dir, desktop: desk)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)

        let url = try writer.write(Data([1, 2, 3]), named: "frame.png")
        #expect(url.lastPathComponent == "frame.png")
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        try writer.write(Data([9]), named: "frame.png")
        #expect(try Data(contentsOf: url) == Data([9]))

        for bad in ["", ".", "..", "a/b", "../escape.png"] {
            #expect(throws: ArtifactWriter.Failure.invalidName(bad)) { try writer.write(Data(), named: bad) }
        }
    }
}
