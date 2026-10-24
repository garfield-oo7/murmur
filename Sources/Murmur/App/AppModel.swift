import AppKit
import SwiftUI

/// Everything the app owns.
@Observable
final class AppModel {
    let permissions = Permissions()
    let speechModel = SpeechModel()
    let hotkey = HotkeyManager()
    let dictation = DictationController()
    let launchAtLogin = LaunchAtLogin()
    @ObservationIgnored private(set) lazy var status = StatusBroadcaster(dictation: dictation)

    // An AppKit-owned window rather than a SwiftUI `Window` scene: a menu bar app
    // launched in the background doesn't reliably get scene windows on screen.
    @ObservationIgnored private var setupWindow: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?

    init() {
        hotkey.onPress = { [dictation] in dictation.keyDown() }
        hotkey.onRelease = { [dictation] in dictation.keyUp() }
        hotkey.onCancel = { [dictation] in dictation.cancel() }
        hotkey.onRestart = { [dictation] in dictation.restart() }
        dictation.onError = { [weak self] error in
            switch error {
            case .microphoneNotAllowed, .modelNotInstalled, .accessibilityNotAllowed: self?.showSetup()
            case .noMicrophone: break
            }
        }
        hotkey.register()
    }

    func showSetup() {
        if setupWindow == nil {
            let window = Self.makeWindow(SetupView(model: self), title: "Set Up Murmur")
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            setupWindow = window
        }
        NSApp.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = Self.makeWindow(SettingsView(model: self), title: "Murmur Settings")
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow(_ view: some View, title: String) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    func closeSetup() {
        setupWindow?.close()
    }
}
