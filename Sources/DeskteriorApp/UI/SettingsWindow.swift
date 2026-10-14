import AppKit
import DeskCore
import Observation
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
}

/// The Settings window's state: the settings, the model's lights, the mirrored folder, the displays and the login
/// item's status line.
@Observable
final class SettingsModel {
    var settings: DeskSettings
    var lights: LightsMode
    var folderPath: String
    /// `--desktop-folder` chose the folder for this run.
    var folderLocked: Bool
    var displays: [(uuid: String, name: String)]
    var loginStatus: String?
    var folderNote: String?
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

/// Settings (DESIGN §4.8; M12), a small SwiftUI form: lights, Reduce Motion, the desk mat, the mirrored folder, the
/// Peek hotkey and Launch at Login (both off until turned on here), pausing on battery, the desk display and the
/// other displays' walls, the language, and About & Credits.
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
                Text(tr(.peekHotkeyNote)).font(.caption).foregroundStyle(.secondary)
                Toggle(tr(.launchAtLogin), isOn: Binding(get: { model.settings.launchAtLogin },
                                                         set: { model.actions.setLaunchAtLogin($0) }))
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

    /// Brings `window` forward and activates the app (an accessory app's windows need it).
    static func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
