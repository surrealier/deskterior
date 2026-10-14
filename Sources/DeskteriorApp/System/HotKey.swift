import AppKit
import Carbon.HIToolbox
import DeskCore

/// The optional global Peek Desk hotkey (⌃⌥⌘D; DESIGN §2.2 E16) through Carbon's `RegisterEventHotKey`, which needs
/// no Accessibility permission. Off by default: `HotKeyPolicy` registers it only while the Settings toggle is on.
/// Carbon delivers the press on the main thread's event loop.
final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void

    /// "DskT".
    private static let signature: OSType = 0x4473_6B54

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    func registerHotKey(_ binding: HotKeyBinding) -> Bool {
        unregisterHotKey()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { me.onPress() }
            return noErr
        }, 1, &spec, context, &handler)
        guard installed == noErr else { return false }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            unregisterHotKey()
            return false
        }
        return true
    }

    func unregisterHotKey() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

/// A registrar that only records (every mode but desk mode: development runs never claim a real global key).
final class RecordingHotKeyRegistrar: HotKeyRegistrar {
    private(set) var calls: [String] = []

    func registerHotKey(_ binding: HotKeyBinding) -> Bool {
        calls.append("register \(binding.keyCode)/\(binding.modifiers)")
        Log.info("hotkey: would register ⌃⌥⌘D (not in desk mode)")
        return true
    }

    func unregisterHotKey() {
        calls.append("unregister")
        Log.info("hotkey: would unregister (not in desk mode)")
    }
}
