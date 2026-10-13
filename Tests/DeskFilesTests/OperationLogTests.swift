import Foundation
import Testing
@testable import DeskFiles

@Suite("OperationLog")
struct OperationLogTests {
    static func entry(_ n: Int, outcome: String = "ok") -> OperationLog.Entry {
        OperationLog.Entry(
            time: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)), op: .trash, origin: .menuItem,
            names: ["file \(n).txt"], inodes: [UInt64(1000 + n)], outcome: outcome
        )
    }

    @Test("Each entry is one JSON line with time, op, origin, names, inodes and outcome")
    func jsonLines() throws {
        let d = try TempDesk()
        let log = try OperationLog(directory: d.url("State"), desktop: d.url("Desk"))
        try log.append(Self.entry(1))
        try log.append(OperationLog.Entry(
            time: Date(timeIntervalSince1970: 1_800_000_002), op: .importCopy, origin: .drop,
            names: ["보고서.pdf", "보고서 2.pdf"], inodes: [7, 8], outcome: "renamed"
        ))
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3 && lines[2].isEmpty)
        #expect(lines[0] == #"{"inodes":[1001],"names":["file 1.txt"],"op":"trash","origin":"menuItem","outcome":"ok","time":"2027-01-15T08:00:01Z"}"#)
        #expect(lines[1].contains(#""op":"import-copy""#))
        #expect(log.entries().map(\.names) == [["file 1.txt"], ["보고서.pdf", "보고서 2.pdf"]])
        #expect(log.entries().last?.inodes == [7, 8])
    }

    @Test("Appending never rewrites earlier lines")
    func appendOnly() throws {
        let d = try TempDesk()
        let log = try OperationLog(directory: d.url("State"), desktop: d.url("Desk"))
        var previous = Data()
        for n in 0..<20 {
            try log.append(Self.entry(n))
            let now = try Data(contentsOf: log.fileURL)
            #expect(now.starts(with: previous))
            #expect(now.count > previous.count)
            previous = now
        }
        #expect(log.entries().count == 20)
    }

    @Test("A full log rotates to operations.log.1 and stays under twice the cap")
    func rotation() throws {
        let d = try TempDesk()
        let cap = 600
        let log = try OperationLog(directory: d.url("State"), desktop: d.url("Desk"), maxBytes: cap)
        let lineBytes = OperationLog.encode(Self.entry(10)).utf8.count + 1
        for n in 10..<40 {
            try log.append(Self.entry(n))
            let size = (try? Data(contentsOf: log.fileURL).count) ?? 0
            let rotated = (try? Data(contentsOf: log.rotatedURL).count) ?? 0
            #expect(size <= cap)
            #expect(size + rotated <= 2 * cap)
        }
        #expect(FileManager.default.fileExists(atPath: log.rotatedURL.path))
        let kept = log.entries()
        #expect(kept.last == Self.entry(39))
        #expect(kept.count >= cap / lineBytes)
        // Oldest first, no gaps: the rotated file, then the current one.
        let numbers = kept.map { Int($0.inodes[0]) - 1000 }
        #expect(numbers == Array(numbers[0]...39))
        let files = try FileManager.default.contentsOfDirectory(atPath: d.url("State").path).sorted()
        #expect(files == ["operations.log", "operations.log.1"])
    }

    @Test("The log refuses a folder inside the desktop folder or the mirrored folder")
    func refusesDesktop() throws {
        let d = try TempDesk()
        let desk = try d.mkdir("Desk")
        let mirrored = try d.mkdir("Mirrored")
        #expect(throws: SafetyGuard.Refusal.self) { try OperationLog(directory: desk.appendingPathComponent("State"), desktop: desk) }
        #expect(throws: SafetyGuard.Refusal.self) {
            try OperationLog(directory: mirrored, desktop: desk, mirrored: mirrored)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.path).isEmpty)
    }

    @Test("A symlink planted at operations.log is not followed")
    func noSymlinkFollow() throws {
        let d = try TempDesk()
        let log = try OperationLog(directory: d.url("State"), desktop: d.url("Desk"))
        let victim = try d.write("victim.txt", "untouched")
        try FileManager.default.createSymbolicLink(at: log.fileURL, withDestinationURL: victim)
        #expect(throws: OperationLog.Failure.self) { try log.append(Self.entry(1)) }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "untouched")
    }

    @Test("A FIFO planted at operations.log is refused at once instead of blocking every file action")
    func plantedFIFO() throws {
        let d = try TempDesk()
        let log = try OperationLog(directory: d.url("State"), desktop: d.url("Desk"))
        #expect(mkfifo(log.fileURL.path, 0o600) == 0)
        let done = DispatchSemaphore(value: 0)
        let results = Recorder<Bool>()
        // A thread of its own, so a busy test run cannot delay it the way it can a GCD worker.
        Thread.detachNewThread {
            results.append((try? log.append(Self.entry(1))) == nil)
            results.append(log.entries().isEmpty)
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 30) == .success
        if !finished {
            // Release a stuck open so the test run goes on.
            for flags in [O_RDONLY | O_NONBLOCK, O_WRONLY | O_NONBLOCK] {
                let fd = open(log.fileURL.path, flags)
                if fd >= 0 { close(fd) }
            }
            _ = done.wait(timeout: .now() + 3)
        }
        #expect(finished)
        #expect(results.all == [true, true])
    }
}
