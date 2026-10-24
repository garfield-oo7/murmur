import AppKit
import ApplicationServices
import AVFoundation

/// Microphone and Accessibility status. Speech Recognition permission isn't needed:
/// M1 showed on-device SpeechAnalyzer works while it stays `notDetermined`.
@Observable
final class Permissions {
    private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var accessibility = AXIsProcessTrusted()

    var microphoneGranted: Bool { microphone == .authorized }
    var allGranted: Bool { microphoneGranted && accessibility }

    /// There is no reliable notification for Accessibility changes, so callers poll this
    /// while the setup window is open.
    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }
    }

    func requestMicrophone() async {
        switch microphone {
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
        default:
            // Denied once: macOS won't ask again, the user has to flip it in Settings.
            open(.microphone)
        }
    }

    func requestAccessibility() {
        // Shows the system "would like to control this computer" alert the first time
        // and adds Murmur to the list; afterwards it does nothing, so also open Settings.
        // (String key instead of kAXTrustedCheckOptionPrompt, a non-Sendable C global.)
        // Re-prompting just stacks that alert on top of Settings, so only ask once.
        if UserDefaults.standard.bool(forKey: "askedForAccessibility") {
            open(.accessibility)
        } else {
            UserDefaults.standard.set(true, forKey: "askedForAccessibility")
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
    }

    func open(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }
}
