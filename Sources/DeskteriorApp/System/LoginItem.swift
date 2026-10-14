import DeskCore
import Foundation
import ServiceManagement

/// Launch at Login through `SMAppService.mainApp` (DESIGN §4.8). `SMAppService` calls can block, so the controller
/// runs them on a utility queue and reports back on the main actor; `LoginItemPolicy` decides what to call (never
/// anything while the setting is off; re-register after an update only if the user opted in).
nonisolated final class MainAppLoginItem: LoginItemService, @unchecked Sendable {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// A login item that only records (every mode but desk mode: development runs never add a real login item).
nonisolated final class RecordingLoginItem: LoginItemService, @unchecked Sendable {
    private let lock = NSLock()
    private var registered = false
    private var log: [String] = []

    var status: LoginItemStatus { lock.withLock { registered ? .enabled : .notRegistered } }

    func register() throws {
        lock.withLock {
            registered = true
            log.append("register")
        }
    }

    func unregister() throws {
        lock.withLock {
            registered = false
            log.append("unregister")
        }
    }

    var calls: [String] { lock.withLock { log } }
}

/// Runs `LoginItemPolicy` off the main thread and hands the outcome and the updated settings back on the main actor.
final class LoginItemController {
    let service: any LoginItemService
    let version: String
    private let queue = DispatchQueue(label: "deskterior.loginItem", qos: .utility)

    init(service: any LoginItemService, version: String = AppVersion.current) {
        self.service = service
        self.version = version
    }

    /// The launch check (re-registers after an update while opted in; nothing at all while off or translocated).
    func launchCheck(_ settings: DeskSettings, translocated: Bool,
                     done: @escaping @MainActor (DeskSettings, LoginItemOutcome) -> Void) {
        guard settings.launchAtLogin, !translocated else { return }
        run(settings, done: done) { s, version, service in
            LoginItemPolicy.launch(&s, version: version, service: service, translocated: translocated)
        }
    }

    /// The Settings toggle.
    func set(_ on: Bool, _ settings: DeskSettings, done: @escaping @MainActor (DeskSettings, LoginItemOutcome) -> Void) {
        run(settings, done: done) { s, version, service in LoginItemPolicy.set(on, &s, version: version, service: service) }
    }

    /// The service's status, read off the main thread.
    func readStatus(_ done: @escaping @MainActor (LoginItemStatus) -> Void) {
        let service = service
        queue.async {
            let status = service.status
            DispatchQueue.main.async { MainActor.assumeIsolated { done(status) } }
        }
    }

    private func run(_ settings: DeskSettings, done: @escaping @MainActor (DeskSettings, LoginItemOutcome) -> Void,
                     _ body: @escaping @Sendable (inout DeskSettings, String, any LoginItemService) -> LoginItemOutcome) {
        let service = service, version = version
        queue.async {
            var s = settings
            let outcome = body(&s, version, service)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(s, outcome) } }
        }
    }
}

/// The app's version for the login item's bookkeeping: the bundle's short version and build, or the core's version
/// when unbundled.
enum AppVersion {
    static var current: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String else { return DeskCore.version }
        return [short, info["CFBundleVersion"] as? String].compactMap { $0 }.joined(separator: " ")
    }
}
