#if !canImport(os)
import Foundation

/// The unified log's stand-in where the `os` module does not exist (Linux, Windows): one line on standard error
/// per message, `[deskterior/<category>] <level>: <message>`. Apple platforms keep `os.Logger`, so nothing here is
/// compiled there. Messages that the Apple code marks private (file names in `OperationLog`) are passed through
/// `redacted` by the caller instead.
public struct PlatformLog: Sendable {
    public let category: String

    public init(category: String) {
        self.category = category
    }

    public func notice(_ message: String) { write("notice", message) }
    public func error(_ message: String) { write("error", message) }
    public func fault(_ message: String) { write("fault", message) }

    /// What a private value prints as: its length only.
    public static func redacted(_ value: String) -> String { "<private \(value.count)>" }

    private func write(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("[deskterior/\(category)] \(level): \(message)\n".utf8))
    }
}
#endif
