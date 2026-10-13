import DeskCore
import DeskPixels
import Foundation

/// Exact PNG goldens for `PixelBuffer`s, stored next to the calling test file in `Goldens/<name>.png`.
///
/// - `RECORD_SNAPSHOTS=1` (re)writes the golden and passes.
/// - On a mismatch (or a missing golden) the actual image is written to
///   `$TMPDIR/deskterior-golden-failures/<name>.png` and its path is printed.
///
/// This file is identical in every test target that uses goldens.
enum Golden {
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
    }

    /// `<directory of filePath>/Goldens/<name>.png`.
    static func url(_ name: String, filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
            .appendingPathComponent("\(name).png", isDirectory: false)
    }

    /// True when `b` equals the golden pixel for pixel (or when recording).
    static func match(_ b: PixelBuffer, _ name: String, filePath: String = #filePath) -> Bool {
        let golden = url(name, filePath: filePath)
        if isRecording {
            do {
                try FileManager.default.createDirectory(
                    at: golden.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try PNGCodec.encode(b).write(to: golden, options: .atomic)
                print("Golden: recorded \(golden.path)")
                return true
            } catch {
                print("Golden: could not record \(golden.path): \(error)")
                return false
            }
        }

        guard let data = try? Data(contentsOf: golden), let expected = PNGCodec.decode(data) else {
            let actual = writeFailure(b, name)
            print("Golden: missing \(golden.path) (record with RECORD_SNAPSHOTS=1); actual: \(actual)")
            return false
        }
        if expected == b { return true }

        let actual = writeFailure(b, name)
        if expected.size != b.size {
            print("Golden '\(name)': size \(b.size) != expected \(expected.size); actual: \(actual)")
        } else {
            let diffs = zip(expected.pixels, b.pixels).enumerated().filter { $0.element.0 != $0.element.1 }
            let first = diffs[0]
            let x = first.offset % b.width, y = first.offset / b.width
            print(
                "Golden '\(name)': \(diffs.count) pixel(s) differ; first at (\(x),\(y)): "
                    + "\(b.pixels[first.offset]) != expected \(expected.pixels[first.offset]); actual: \(actual)"
            )
        }
        return false
    }

    /// Writes `b` to the failure directory and returns its path.
    @discardableResult
    static func writeFailure(_ b: PixelBuffer, _ name: String) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskterior-golden-failures", isDirectory: true)
        let file = dir.appendingPathComponent("\(name).png", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try PNGCodec.encode(b).write(to: file, options: .atomic)
            return file.path
        } catch {
            return "(could not write \(file.path): \(error))"
        }
    }
}

/// Foundation access for test files. With only the Command Line Tools installed, a file that imports both
/// `Testing` and `Foundation` fails to build (the `_Testing_Foundation` cross-import overlay ships without its
/// module), so `@Test` files do not import Foundation and use these helpers instead.
enum TestSupport {
    static func environment(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    static func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// The repo root for a test file in `<repo>/Tests/<Target>/` (or a subdirectory one level deeper).
    static func repoRoot(testFile: String = #filePath) -> String {
        var url = URL(fileURLWithPath: testFile).deletingLastPathComponent()
        while url.path != "/" && url.lastPathComponent != "Tests" { url = url.deletingLastPathComponent() }
        return url.deletingLastPathComponent().standardizedFileURL.path
    }

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func nfd(_ s: String) -> String {
        s.decomposedStringWithCanonicalMapping
    }

    /// Writes `b` as `<dir>/<name>.png`, creating `dir`.
    static func writePNG(_ b: PixelBuffer, directory dir: String, name: String) throws {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try PNGCodec.encode(b).write(to: url.appendingPathComponent("\(name).png"), options: .atomic)
    }
}
