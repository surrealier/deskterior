import AppKit
import DeskCore
import DeskFiles
import DeskPixels
import DeskScene

// Bootstrap stub; replaced by the real AppDelegate in M2.
if CommandLine.arguments.contains("--version") {
    print("Deskterior \(DeskCore.version)")
    exit(0)
}
print("Deskterior \(DeskCore.version) — app shell not implemented yet (M2).")
