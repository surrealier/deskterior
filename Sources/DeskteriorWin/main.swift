import DeskCore
import DeskFiles
import Foundation

// Deskterior for Windows (docs/WINDOWS.md WP6): the desk in a window of its own, or a headless snapshot.

L10n.platform = .windows
let environment = ProcessInfo.processInfo.environment
let options: WinOptions
do {
    options = try WinOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n\(WinOptions.usage)\n".utf8))
    exit(64)
}
if options.help {
    print(WinOptions.usage)
    exit(0)
}
if let language = options.language { L10n.language = language == "ko" ? .ko : .en }

if options.snapshot != nil {
    do {
        let report = try MainActor.assumeIsolated { try Snapshot.run(options, environment: environment) }
        print(report)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        exit(1)
    }
}

#if os(Windows)
MainActor.assumeIsolated { WinApp.run(options, environment: environment) }
#else
FileHandle.standardError.write(Data("This build only renders snapshots here (--snapshot); the window is Windows only.\n".utf8))
exit(64)
#endif
