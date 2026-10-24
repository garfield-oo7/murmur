import os
import ServiceManagement

/// "Open Murmur at login" via SMAppService (shows up in System Settings → General →
/// Login Items & Extensions).
@Observable
final class LaunchAtLogin {
    private(set) var status = SMAppService.mainApp.status
    private(set) var lastError: String?

    private static let log = Logger(subsystem: "io.github.garfield-oo7.Murmur", category: "login-item")
    private static let configuredKey = "launchAtLoginConfigured"

    var isEnabled: Bool { status == .enabled }
    /// The user turned it off in System Settings, or macOS wants them to confirm there.
    var needsApproval: Bool { status == .requiresApproval }

    /// Turns it on once, on the first launch of a version that has the feature. After
    /// that it's the user's setting and is never changed behind their back.
    func enableOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.configuredKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.configuredKey)
        set(true)
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            Self.log.error("\(enabled ? "register" : "unregister", privacy: .public) failed: \(error, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
        Self.log.notice("login item status: \(String(describing: self.status), privacy: .public)")
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
