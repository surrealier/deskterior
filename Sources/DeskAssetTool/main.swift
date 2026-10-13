import DeskCore
import DeskPixels
import Foundation

// `deskterior-assets` dev tool: icon, contact-sheet, fixture subcommands (filled in later milestones).
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("usage: deskterior-assets <icon|contact-sheet|fixture> [options]")
    exit(2)
}
print("deskterior-assets: '\(command)' not implemented yet")
exit(2)
