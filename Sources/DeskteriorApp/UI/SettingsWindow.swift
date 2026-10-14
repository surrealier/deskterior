import AppKit
import DeskCore
import Observation
import QuickLookUI
import SwiftUI

/// What the Settings window changes, implemented by `AppSystem` (each takes effect at once).
struct SettingsActions {
    var setLights: (LightsMode) -> Void = { _ in }
    var update: ((inout DeskSettings) -> Void) -> Void = { _ in }
    var setHotkey: (Bool) -> Void = { _ in }
    var setLaunchAtLogin: (Bool) -> Void = { _ in }
    var chooseFolder: () -> Void = {}
    var useDesktop: () -> Void = {}
    var showAbout: () -> Void = {}
    // MARK: harden
    var showLeftovers: () -> Void = {}
    var trashLeftovers: () -> Void = {}
}

/// The Settings window's state: the settings, the model's lights, the mirrored folder, the displays and the status
/// lines of the hotkey and the login item.
@Observable
final class SettingsModel {
    var settings: DeskSettings
    var lights: LightsMode
    var folderPath: String
    /// `--desktop-folder` chose the folder for this run.
    var folderLocked: Bool
    /// `--pixel-size` chose the pixel size for this run.
    var pixelSizeLocked = false
    /// Running from a translocated copy: Launch at Login is unavailable (`loginStatus` says why).
    var loginLocked = false
    var displays: [(uuid: String, name: String)]
    var loginStatus: String?
    var hotkeyStatus: String?
    var folderNote: String?
    // MARK: harden
    /// Leftover copies found in the mirrored folder, and what the last Move to Trash said.
    var leftovers = 0
    var leftoverNote: String?
    @ObservationIgnored var actions = SettingsActions()

    init(settings: DeskSettings, lights: LightsMode, folderPath: String, folderLocked: Bool,
         displays: [(uuid: String, name: String)]) {
        self.settings = settings
        self.lights = lights
        self.folderPath = folderPath
        self.folderLocked = folderLocked
        self.displays = displays
    }

    func binding<T>(_ path: WritableKeyPath<DeskSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: path] }, set: { v in self.actions.update { $0[keyPath: path] = v } })
    }
}

/// Settings (DESIGN §4.8; M12), a small SwiftUI form: lights, Reduce Motion, the pixel size, the mirrored folder, the
/// Peek hotkey and Launch at Login (both off until turned on here), pausing on battery, the desk display and the
/// other displays' walls, the language, the desk mat's Cloth/Flat, and About & Credits.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let _ = model.settings.language
        Form {
            Section(tr(.settingsDesk)) {
                Picker(tr(.lightsMode), selection: Binding(get: { model.lights }, set: { model.actions.setLights($0) })) {
                    Text(tr(.lightsAuto)).tag(LightsMode.auto)
                    Text(tr(.lightsDay)).tag(LightsMode.day)
                    Text(tr(.lightsNight)).tag(LightsMode.night)
                    Text(tr(.lightsLampOnly)).tag(LightsMode.lampOnly)
                }
                Picker(tr(.reduceMotion), selection: model.binding(\.reduceMotion)) {
                    Text(tr(.reduceMotionFollow)).tag(DeskSettings.ReduceMotion.followSystem)
                    Text(tr(.reduceMotionOn)).tag(DeskSettings.ReduceMotion.on)
                    Text(tr(.reduceMotionOff)).tag(DeskSettings.ReduceMotion.off)
                }
                Picker(tr(.matMode), selection: model.binding(\.matMode)) {
                    Text(tr(.matCloth)).tag(DeskSettings.MatMode.cloth)
                    Text(tr(.matFlat)).tag(DeskSettings.MatMode.flat)
                }
                Picker(tr(.pixelSize), selection: model.binding(\.pixelSize)) {
                    Text(tr(.pixelChunky)).tag(PixelSize.chunky)
                    Text(tr(.pixelNormal)).tag(PixelSize.normal)
                    Text(tr(.pixelFine)).tag(PixelSize.fine)
                }
                .disabled(model.pixelSizeLocked)
            }
            Section(tr(.mirroredFolder)) {
                Text(model.folderPath).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                HStack {
                    Button(tr(.cardChooseFolder)) { model.actions.chooseFolder() }
                    Button(tr(.useDesktop)) { model.actions.useDesktop() }
                        .disabled(model.settings.mirroredFolder == nil)
                }
                .disabled(model.folderLocked)
                if model.folderLocked {
                    Text(tr(.folderSetByFlag)).font(.caption).foregroundStyle(.secondary)
                } else if let note = model.folderNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(tr(.settingsSystem)) {
                Toggle(tr(.peekHotkey), isOn: Binding(get: { model.settings.peekHotkeyEnabled },
                                                      set: { model.actions.setHotkey($0) }))
                Text(model.hotkeyStatus ?? tr(.peekHotkeyNote)).font(.caption).foregroundStyle(.secondary)
                Toggle(tr(.launchAtLogin), isOn: Binding(get: { model.settings.launchAtLogin },
                                                         set: { model.actions.setLaunchAtLogin($0) }))
                    .disabled(model.loginLocked)
                if let status = model.loginStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(tr(.pauseOnBattery), isOn: model.binding(\.pauseOnBattery))
                if model.displays.count > 1 {
                    Picker(tr(.deskDisplay), selection: model.binding(\.deskDisplayUUID)) {
                        Text(tr(.mainDisplay)).tag(String?.none)
                        ForEach(model.displays, id: \.uuid) { d in Text(d.name).tag(Optional(d.uuid)) }
                    }
                    Toggle(tr(.coverDisplays), isOn: Binding(get: { model.settings.coverOtherDisplays == true },
                                                             set: { v in model.actions.update { $0.coverOtherDisplays = v } }))
                }
                Picker(tr(.language), selection: model.binding(\.language)) {
                    Text(tr(.languageSystem)).tag(LanguageSetting.system)
                    Text(tr(.languageEnglish)).tag(LanguageSetting.en)
                    Text(tr(.languageKorean)).tag(LanguageSetting.ko)
                }
            }
            // MARK: harden
            if model.leftovers > 0 || model.leftoverNote != nil {
                Section(tr(.leftoversTitle)) {
                    if model.leftovers > 0 {
                        Text(L10n.format(model.leftovers == 1 ? .leftoversOne : .leftoversMany, [model.leftovers]))
                        Text(tr(.leftoversExplain)).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(tr(.showInFinder)) { model.actions.showLeftovers() }
                            Button(tr(.moveToTrash)) { model.actions.trashLeftovers() }
                        }
                    }
                    if let note = model.leftoverNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button(tr(.aboutCredits)) { model.actions.showAbout() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Hosts a SwiftUI view in a plain titled window (Settings, About, Safe Mode, onboarding and notes).
enum AppWindow {
    static func make(title: String, view: some View, closable: Bool = true) -> NSWindow {
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.styleMask = closable ? [.titled, .closable] : [.titled]
        w.title = title
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.center()
        return w
    }

    /// The level the app's own windows take: normal, or just above the desk while Peek Desk floats it (`PeekPolicy`).
    private(set) static var level: NSWindow.Level = .normal

    /// Brings `window` forward at `level` and activates the app (an accessory app's windows need it).
    static func present(_ window: NSWindow) {
        window.level = level
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Moves the app's titled windows (not the desk) and the Quick Look panel to `new`, and opens later ones there.
    static func setLevel(_ new: NSWindow.Level) {
        guard new != level else { return }
        level = new
        // Open and save panels keep their own (modal) level.
        for w in NSApp.windows where w.styleMask.contains(.titled) && !(w is WindowedDeskWindow || w is NSSavePanel) {
            w.level = new
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() { panel.level = new }
    }
}
