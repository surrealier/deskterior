import Carbon
// inputsrc: prints the current keyboard input source id; inputsrc ID selects that source.
let args = CommandLine.arguments
if args.count > 1 {
    let filter = [kTISPropertyInputSourceID as String: args[1]] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource], let s = list.first else { print("not found"); exit(1) }
    print("select", TISSelectInputSource(s))
}
let cur = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
let id = Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(cur, kTISPropertyInputSourceID)).takeUnretainedValue()
print(id)
